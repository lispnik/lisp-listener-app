;;;; src/ios/canvas-sheet.lisp -- the canvas, as a sheet over the listener.
;;;;
;;;; iOS's half of src/canvas.lisp: a UIView whose -drawRect: is PAINT-CANVAS,
;;;; in a sheet that comes up at half height when anything is drawn, so that
;;;; the transcript is still there above it.  Done, a drag downwards, or a tap
;;;; on the transcript puts it away; what was drawn is kept.
;;;;
;;;; A phone has no arrow keys, so the sheet has them: a row of buttons under
;;;; the canvas that are the keys (key) answers.  Buttons and not swipes,
;;;; because a sheet already has a meaning for a vertical drag -- it moves the
;;;; sheet -- and a snake steered by one would close its own window.
;;;;
;;;; One controller, made once and kept: the canvas is the image's, not any one
;;;; presentation's, and it is presented again each time it is wanted.
;;;;
;;;; Thread 1, all of it.

(in-package #:lisp-listener)

(defparameter *canvas-pad-height* 48d0)

(defvar *canvas-controller* nil
  "The sheet's UIViewController, retained, or NIL before anything is drawn.
Made at run time: a pointer made at load time would not survive into the app.")

(defvar *canvas-view* nil
  "The Lisp object behind the canvas's view, held so that it stays.")

(defvar *canvas-pad* '()
  "The sheet's keys, as (KEY . BUTTON), and Done as :DONE, for the self-test
to press.")

(defun canvas-toolkit () :uikit)

(objc:define-objc-class canvas-view ()
  ()
  (:objc-class-name "LispListenerCanvasView")
  (:objc-superclass-name "UIView"))

(objc:define-objc-method ("drawRect:" :void)
    ((self canvas-view pointer) (dirty cocoa:ns-rect))
  (declare (ignorable dirty))
  ;; Nothing may unwind into UIKit.
  (handler-case
      (let ((bounds (objc:invoke pointer "bounds")))
        (paint-canvas (aref bounds 2) (aref bounds 3)))
    (error (condition) (note "canvas drawRect: ~a" condition))))

;;; The view is the sheet's delegate too.  UIKit sends this when the person
;;; dismisses the sheet by hand, and not when the program does.
(objc:define-objc-method ("presentationControllerDidDismiss:" :void)
    ((self canvas-view) (presentation objc:objc-object-pointer))
  (declare (ignorable presentation))
  (handler-case (canvas-closed-by-person)
    (error (condition) (note "canvas presentationControllerDidDismiss: ~a" condition))))

(defun canvas-view-pointer ()
  (and *canvas-view* (objc:objc-object-pointer *canvas-view*)))

(defun build-canvas-sheet ()
  "The sheet's controller: Done, the canvas, and the row of keys.  Kept."
  (let* ((controller (objc:invoke (objc:invoke "UIViewController" "alloc") "init"))
         (root (objc:invoke controller "view"))
         (object (make-instance 'canvas-view))
         (view (objc:objc-object-pointer object))
         (done (uikit:system-button "Done"))
         (pad (uikit:new "UIStackView")))
    (objc:invoke root "setBackgroundColor:"
                 (objc:invoke "UIColor" "systemBackgroundColor"))
    (objc:invoke view "setTranslatesAutoresizingMaskIntoConstraints:" nil)
    ;; UIViewContentModeRedraw: a new picture when the sheet is dragged taller
    ;; or the phone is turned, not the old one stretched.
    (objc:invoke view "setContentMode:" 3)
    (objc:invoke view "setOpaque:" t)
    (uikit:on-tap done (lambda (sender)
                         (declare (ignore sender))
                         (canvas-closed-by-person)
                         (hide-canvas)))
    (objc:invoke pad "setAxis:" 0)              ; horizontal
    (objc:invoke pad "setDistribution:" 1)      ; fill equally
    (setf *canvas-pad* '())
    (loop for (title key) in '(("←" :left) ("↑" :up) ("↓" :down) ("→" :right)
                               ("●" :space))
          do (let ((button (uikit:system-button title))
                   (key key))
               (objc:invoke (objc:invoke button "titleLabel") "setFont:" (uikit:font 24))
               (uikit:on-tap button (lambda (sender)
                                      (declare (ignore sender))
                                      (canvas-push-key key)))
               (objc:invoke pad "addArrangedSubview:" button)
               (push (cons key button) *canvas-pad*)))
    (push (cons :done done) *canvas-pad*)
    (objc:invoke root "addSubview:" done)
    (objc:invoke root "addSubview:" view)
    (objc:invoke root "addSubview:" pad)
    (let ((safe (objc:invoke root "safeAreaLayoutGuide")))
      (uikit:pin done "topAnchor" root "topAnchor" 14)
      (uikit:pin done "trailingAnchor" safe "trailingAnchor" -16)
      (uikit:pin view "topAnchor" done "bottomAnchor" 6)
      (uikit:pin view "leadingAnchor" root "leadingAnchor")
      (uikit:pin view "trailingAnchor" root "trailingAnchor")
      (uikit:pin view "bottomAnchor" pad "topAnchor")
      (uikit:pin pad "leadingAnchor" safe "leadingAnchor" 16)
      (uikit:pin pad "trailingAnchor" safe "trailingAnchor" -16)
      (uikit:pin pad "bottomAnchor" safe "bottomAnchor")
      (uikit:fix pad "heightAnchor" *canvas-pad-height*))
    (let ((sheet (objc:invoke controller "sheetPresentationController")))
      (when (live-pointer-p sheet)
        (let ((detents (objc:invoke "NSMutableArray" "array")))
          (objc:invoke detents "addObject:"
                       (objc:invoke "UISheetPresentationControllerDetent" "mediumDetent"))
          (objc:invoke detents "addObject:"
                       (objc:invoke "UISheetPresentationControllerDetent" "largeDetent"))
          (objc:invoke sheet "setDetents:" detents)
          (objc:invoke sheet "setPrefersGrabberVisible:" t)
          ;; To hear of a drag downwards or a tap outside; Done says so itself.
          ;; A weak reference, and the view is kept below.
          (objc:invoke sheet "setDelegate:" view))))
    ;; The +1 from -alloc is kept for the life of the app.
    (setf *canvas-view* object
          *canvas-controller* controller)))

(defun canvas-visible-p ()
  (and (live-pointer-p *canvas-controller*)
       (live-pointer-p (objc:invoke *canvas-controller* "presentingViewController"))))

(defun show-canvas (&key keyboard)
  "Present the sheet, if it is not up.  KEYBOARD means nothing here: the keys
are in the sheet.

Not animated.  A sheet still sliding up cannot have another presented over it,
and the form that drew may be about to signal: the restarts would be asked to
appear over a transition in flight, and UIKit drops such a request."
  (declare (ignore keyboard))
  (unless (live-pointer-p *canvas-controller*)
    (build-canvas-sheet))
  (unless (canvas-visible-p)
    (let ((listener (current-listener)))
      (when listener
        (objc:invoke (presenting-controller listener)
                     "presentViewController:animated:completion:"
                     *canvas-controller* nil nil))))
  t)

(defun hide-canvas ()
  "Dismiss the sheet.  What was drawn is kept, and drawing presents it again."
  (when (canvas-visible-p)
    (objc:invoke *canvas-controller* "dismissViewControllerAnimated:completion:" t nil))
  t)

(defun redisplay-canvas ()
  "Repaint, presenting the sheet first if it is not up."
  (show-canvas)
  (objc:invoke (canvas-view-pointer) "setNeedsDisplay")
  t)

(defun press-canvas-key (key)
  "Press the sheet's button for KEY, as a finger would.  For the self-test."
  (let ((button (cdr (assoc key *canvas-pad*))))
    (when (live-pointer-p button)
      (objc:invoke button "sendActionsForControlEvents:" 64) ; UIControlEventTouchUpInside
      t)))
