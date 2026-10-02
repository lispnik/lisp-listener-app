;;;; src/ios/canvas-sheet.lisp -- the canvas, as a sheet on a phone and a pane
;;;; on an iPad.
;;;;
;;;; iOS's half of src/canvas.lisp: a UIView whose -drawRect: is PAINT-CANVAS,
;;;; in a panel with Done above it and a row of arrow buttons below.
;;;;
;;;; Where the panel goes depends on the room.  On a phone it is a SHEET at half
;;;; height, so the transcript is still there above it.  Where the window is
;;;; wide -- an iPad, a big phone on its side -- it is DOCKED beside the
;;;; transcript, which gives up the right-hand two fifths: the prompt keeps the
;;;; keyboard, so a form can be typed while its picture is in view, and no
;;;; sheet has to be put away first.
;;;;
;;;; A phone has no arrow keys, so the panel has them: buttons that are the
;;;; keys (key) answers.  Buttons and not swipes, because a sheet already has a
;;;; meaning for a vertical drag.  The canvas itself takes the finger: (pointer)
;;;; answers where it is, through a recognizer that claims a touch the moment
;;;; it lands -- which is also what stops the sheet treating a stroke drawn
;;;; downwards as a request to close.
;;;;
;;;; One panel, made once and kept: the canvas is the image's, not any one
;;;; presentation's.
;;;;
;;;; Thread 1, all of it.

(in-package #:lisp-listener)

(defparameter *canvas-pad-height* 48d0)

(defparameter *canvas-dock-width* 700d0
  "The window is wide enough to dock the canvas beside the transcript from
this many points across; narrower, the canvas is a sheet.")

(defparameter *canvas-dock-share* 0.42d0
  "How much of the window's width a docked canvas takes.")

(defparameter *canvas-png-size* 800d0
  "The side of the square (save \"name.png\") draws, in points.")

(defvar *canvas-panel* nil
  "The view holding Done, the canvas and the keys.  Retained; NIL before
anything is drawn.  Made at run time: a pointer made at load time would not
survive into the app.")

(defvar *canvas-controller* nil
  "The sheet's UIViewController, retained, or NIL until a sheet is wanted.")

(defvar *canvas-view* nil
  "The Lisp object behind the canvas's view, held so that it stays.")

(defvar *canvas-pad* '()
  "The panel's keys, as (KEY . BUTTON), and Done as :DONE, for the self-test
to press.")

(defvar *transcript-trailing* nil
  "The constraint that keeps the transcript's right edge at the window's,
retained.  IOS-START makes it; docking the canvas switches it off, and putting
the canvas away switches it back on.")

(defvar *canvas-dock-constraint* nil
  "While the canvas is docked: the constraint holding the transcript's right
edge at the panel's left, retained.")

(defun canvas-toolkit () :uikit)

(defun documents-directory ()
  "Where (save \"name.png\") puts a file that names no directory: the app's
own folder, which is in the Files app."
  (history-directory))

;;; The view ----------------------------------------------------------------------

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

(defun canvas-touch (recognizer)
  "A finger on the canvas: down, moving, or lifted.  UIGestureRecognizerState
is 1 as it begins and 2 while it changes; everything after is the end of it."
  (let* ((view (canvas-view-pointer))
         (point (objc:invoke recognizer "locationInView:" view))
         (bounds (objc:invoke view "bounds")))
    (canvas-pointer-event (case (objc:invoke recognizer "state")
                            (1 :down)
                            (2 :move)
                            (t :up))
                          (aref point 0) (aref point 1)
                          (aref bounds 2) (aref bounds 3))))

;;; The panel ---------------------------------------------------------------------

(defun constraint (view anchor other other-anchor &optional (constant 0))
  "An inactive constraint: VIEW's ANCHOR equals OTHER's OTHER-ANCHOR plus
CONSTANT.  For the ones that are switched on and off; UIKIT:PIN is for the rest."
  (objc:invoke (objc:invoke view anchor) "constraintEqualToAnchor:constant:"
               (objc:invoke other other-anchor) constant))

(defun build-canvas-panel ()
  "The panel: Done, the canvas, and the row of keys.  Kept."
  (let* ((panel (uikit:new "UIView"))
         (object (make-instance 'canvas-view))
         (view (objc:objc-object-pointer object))
         (done (uikit:system-button "Done"))
         (pad (uikit:new "UIStackView"))
         (touch (objc:invoke (objc:invoke "UILongPressGestureRecognizer" "alloc")
                             "initWithTarget:action:"
                             (uikit:action-target #'canvas-touch) "fire:")))
    (objc:invoke panel "setBackgroundColor:"
                 (objc:invoke "UIColor" "secondarySystemBackgroundColor"))
    (objc:invoke view "setTranslatesAutoresizingMaskIntoConstraints:" nil)
    ;; UIViewContentModeRedraw: a new picture when the sheet is dragged taller
    ;; or the device is turned, not the old one stretched.
    (objc:invoke view "setContentMode:" 3)
    (objc:invoke view "setOpaque:" t)
    ;; A long press of no length at all: it begins the instant a finger lands,
    ;; follows it, and ends when it lifts -- a tap and a stroke alike -- and
    ;; having begun, it is the one recognizer that touch belongs to.
    (objc:invoke touch "setMinimumPressDuration:" 0d0)
    (objc:invoke view "addGestureRecognizer:" touch)
    (objc:release touch)
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
    (objc:invoke panel "addSubview:" done)
    (objc:invoke panel "addSubview:" view)
    (objc:invoke panel "addSubview:" pad)
    ;; The panel's own safe area: under a sheet that is the home indicator's,
    ;; and docked it is whatever of the screen's the panel reaches.
    (let ((safe (objc:invoke panel "safeAreaLayoutGuide")))
      (uikit:pin done "topAnchor" safe "topAnchor" 14)
      (uikit:pin done "trailingAnchor" safe "trailingAnchor" -16)
      (uikit:pin view "topAnchor" done "bottomAnchor" 6)
      (uikit:pin view "leadingAnchor" panel "leadingAnchor")
      (uikit:pin view "trailingAnchor" panel "trailingAnchor")
      (uikit:pin view "bottomAnchor" pad "topAnchor")
      (uikit:pin pad "leadingAnchor" safe "leadingAnchor" 16)
      (uikit:pin pad "trailingAnchor" safe "trailingAnchor" -16)
      (uikit:pin pad "bottomAnchor" safe "bottomAnchor")
      (uikit:fix pad "heightAnchor" *canvas-pad-height*))
    (setf *canvas-view* object
          *canvas-panel* (uikit:keep panel))))

(defun ensure-canvas-panel ()
  (unless (live-pointer-p *canvas-panel*)
    (build-canvas-panel))
  *canvas-panel*)

(defun same-view-p (a b)
  (and (live-pointer-p a) (live-pointer-p b) (cffi:pointer-eq a b)))

;;; Docked ------------------------------------------------------------------------

(defun canvas-docks-p ()
  "Whether there is room to put the canvas beside the transcript."
  (let ((root (uikit:root-view)))
    (and (live-pointer-p root)
         (>= (aref (objc:invoke root "bounds") 2) *canvas-dock-width*))))

(defun canvas-docked-p ()
  (and (live-pointer-p *canvas-panel*)
       (same-view-p (objc:invoke *canvas-panel* "superview") (uikit:root-view))))

(defun dock-canvas (listener)
  "Put the panel down the right of the window, and the transcript beside it."
  (let* ((panel (ensure-canvas-panel))
         (root (uikit:root-view))
         (safe (objc:invoke root "safeAreaLayoutGuide"))
         (text (listener-view listener)))
    (objc:invoke panel "removeFromSuperview")
    (objc:invoke root "addSubview:" panel)
    (uikit:pin panel "topAnchor" safe "topAnchor")
    (uikit:pin panel "trailingAnchor" root "trailingAnchor")
    ;; Above the keyboard, like the transcript: the keys are at the bottom.
    (uikit:pin panel "bottomAnchor" (objc:invoke root "keyboardLayoutGuide") "topAnchor")
    (objc:invoke (objc:invoke (objc:invoke panel "widthAnchor")
                              "constraintEqualToAnchor:multiplier:"
                              (objc:invoke root "widthAnchor") *canvas-dock-share*)
                 "setActive:" t)
    (when (live-pointer-p *transcript-trailing*)
      (objc:invoke *transcript-trailing* "setActive:" nil))
    (setf *canvas-dock-constraint*
          (objc:retain (constraint text "trailingAnchor" panel "leadingAnchor" -4)))
    (objc:invoke *canvas-dock-constraint* "setActive:" t)
    (objc:invoke root "layoutIfNeeded")
    t))

(defun undock-canvas ()
  "Take the panel out of the window and give the transcript its width back."
  (when (live-pointer-p *canvas-dock-constraint*)
    (objc:invoke *canvas-dock-constraint* "setActive:" nil)
    (objc:release *canvas-dock-constraint*))
  (setf *canvas-dock-constraint* nil)
  ;; Removing a view takes every constraint between it and what held it.
  (objc:invoke *canvas-panel* "removeFromSuperview")
  (when (live-pointer-p *transcript-trailing*)
    (objc:invoke *transcript-trailing* "setActive:" t))
  t)

;;; As a sheet --------------------------------------------------------------------

(defun build-canvas-sheet ()
  "The sheet's controller, with half and full height to stand at.  Kept."
  (let* ((controller (objc:invoke (objc:invoke "UIViewController" "alloc") "init"))
         (sheet (objc:invoke controller "sheetPresentationController")))
    (objc:invoke (objc:invoke controller "view") "setBackgroundColor:"
                 (objc:invoke "UIColor" "secondarySystemBackgroundColor"))
    (when (live-pointer-p sheet)
      (let ((detents (objc:invoke "NSMutableArray" "array")))
        (objc:invoke detents "addObject:"
                     (objc:invoke "UISheetPresentationControllerDetent" "mediumDetent"))
        (objc:invoke detents "addObject:"
                     (objc:invoke "UISheetPresentationControllerDetent" "largeDetent"))
        (objc:invoke sheet "setDetents:" detents)
        (objc:invoke sheet "setPrefersGrabberVisible:" t)
        ;; To hear of a drag downwards or a tap outside; Done says so itself.
        ;; A weak reference, and the view is kept.
        (objc:invoke sheet "setDelegate:" (canvas-view-pointer))))
    ;; The +1 from -alloc is kept for the life of the app.
    (setf *canvas-controller* controller)))

(defvar *canvas-present-tries* 0
  "How many times in a row presenting the sheet has not taken.")

(defparameter *canvas-present-limit* 12
  "After this many, a quarter of a second apart, it is given up.")

(defun canvas-sheet-up-p ()
  (and (live-pointer-p *canvas-controller*)
       (live-pointer-p (objc:invoke *canvas-controller* "presentingViewController"))))

(defun present-canvas-sheet (listener)
  "Not animated.  A sheet still sliding up cannot have another presented over
it, and the form that drew may be about to signal: the restarts would be asked
to appear over a transition in flight, and UIKit drops such a request."
  (let ((panel (ensure-canvas-panel)))
    (unless (live-pointer-p *canvas-controller*)
      (build-canvas-sheet))
    ;; This controller is kept and presented again, so a dismissal still
    ;; waiting from the last time it was put away must not find it now.
    (cancel-sheet-dismissal *canvas-controller*)
    (let ((root (objc:invoke *canvas-controller* "view")))
      (unless (same-view-p (objc:invoke panel "superview") root)
        (objc:invoke panel "removeFromSuperview")
        (objc:invoke root "addSubview:" panel)
        (uikit:pin panel "topAnchor" root "topAnchor")
        (uikit:pin panel "bottomAnchor" root "bottomAnchor")
        (uikit:pin panel "leadingAnchor" root "leadingAnchor")
        (uikit:pin panel "trailingAnchor" root "trailingAnchor")))
    ;; And it may not take.  UIKit will not present over a sheet that is still
    ;; on its way out -- the Try list, a moment after an example was chosen
    ;; from it -- and says so with a warning or an exception, not a result.
    ;; Nothing would ask again: the drawing is done and no more redisplays are
    ;; coming.  So look, and if the sheet is not up, try again shortly.
    ;; And only when the way is clear: SETTLED-PRESENTER is NIL while another
    ;; sheet is arriving, leaving, or about to be told to leave.
    (let ((presenter (settled-presenter (listener-view listener))))
      (when presenter
        (handler-case (objc:invoke presenter "presentViewController:animated:completion:"
                                   *canvas-controller* nil nil)
          (error (condition) (note "canvas: ~a" condition)))))
    (cond ((canvas-sheet-up-p)
           (setf *canvas-present-tries* 0)
           t)
          ((< (incf *canvas-present-tries*) *canvas-present-limit*)
           (objc:invoke (listener-view listener) "performSelector:withObject:afterDelay:"
                        (objc:coerce-to-selector "listenerShowCanvas") nil 0.25d0)
           nil)
          (t (setf *canvas-present-tries* 0)
             nil))))

;;; When the room changes ---------------------------------------------------------
;;;
;;; A canvas that is up stays where it was put unless the window's width
;;; crosses the line between the two: an iPad turned, or narrowed to share the
;;; screen, or a big phone put on its side.  Then a docked canvas with no room
;;; becomes a sheet, and a sheet with room is docked.

(defvar *canvas-room* :unknown
  "What CANVAS-DOCKS-P last answered, as NOTE-CANVAS-ROOM saw it.")

(defun replace-canvas ()
  "Put a canvas that is on screen where the room now allows.  True if it moved.

Not the person's doing, so nothing is told that the canvas was closed, and a
game goes on."
  (let ((listener (current-listener)))
    (when (and listener (canvas-visible-p))
      (let ((docks (canvas-docks-p)))
        (cond ((and docks (canvas-sheet-up-p))
               ;; Not animated: the panel is about to be in the window.
               (objc:invoke *canvas-controller*
                            "dismissViewControllerAnimated:completion:" nil nil)
               (dock-canvas listener)
               (objc:invoke (canvas-view-pointer) "setNeedsDisplay")
               t)
              ((and (not docks) (canvas-docked-p)
                    ;; A sheet dismissed a moment ago is still on its way out,
                    ;; and UIKit raises if it is presented again before it has
                    ;; gone.  Leave the canvas docked; the next layout asks again.
                    (not (canvas-sheet-up-p)))
               (undock-canvas)
               (present-canvas-sheet listener)
               (objc:invoke (canvas-view-pointer) "setNeedsDisplay")
               t))))))

(defun note-canvas-room (view)
  "Called as the transcript, VIEW, is laid out, which is whenever the window
changes size.  When the answer to `is there room to dock' has changed and the
canvas is in the wrong place for it, ask for it to be moved -- LATER, on the
next pass of the run loop: this is the middle of a layout, and taking a view
out of the hierarchy there is how to get a layout that never settles."
  (let ((docks (ignore-errors (canvas-docks-p))))
    (unless (eq docks *canvas-room*)
      (setf *canvas-room* docks)
      (when (and (canvas-visible-p) (not (eq docks (canvas-docked-p))))
        (objc:invoke view "performSelector:withObject:afterDelay:"
                     (objc:coerce-to-selector "listenerPlaceCanvas") nil 0d0)))))

;;; What the core asks for --------------------------------------------------------

(defun canvas-visible-p ()
  (or (canvas-docked-p) (canvas-sheet-up-p)))

(defun show-canvas (&key keyboard)
  "Put the canvas on screen, if it is not: docked where there is the room, and
as a sheet where there is not.  KEYBOARD means nothing here: the keys are in
the panel."
  (declare (ignore keyboard))
  ;; Wanted, whatever was asked a moment ago.
  (cancel-sheet-dismissal *canvas-controller*)
  (unless (canvas-visible-p)
    (let ((listener (current-listener)))
      (when listener
        (if (canvas-docks-p)
            (dock-canvas listener)
            (present-canvas-sheet listener)))))
  t)

(defun hide-canvas ()
  "Put the canvas away.  What was drawn is kept, and drawing brings it back."
  (cond ((canvas-docked-p) (undock-canvas))
        ((live-pointer-p *canvas-controller*)
         ;; Up, or on its way up: see DISMISS-SHEET-WHEN-SETTLED.
         (let ((listener (current-listener)))
           (when listener
             (dismiss-sheet-when-settled (listener-view listener) *canvas-controller*)))))
  t)

(defun redisplay-canvas ()
  "Repaint, putting the canvas on screen first if it is not."
  (show-canvas)
  (objc:invoke (canvas-view-pointer) "setNeedsDisplay")
  t)

(defun press-canvas-key (key)
  "Press the panel's button for KEY, as a finger would.  For the self-test."
  (let ((button (cdr (assoc key *canvas-pad*))))
    (when (live-pointer-p button)
      (objc:invoke button "sendActionsForControlEvents:" 64) ; UIControlEventTouchUpInside
      t)))

;;; A picture of it ---------------------------------------------------------------

(objc:define-objc-block-type canvas-drawing-actions :void (objc:objc-object-pointer))

(defun save-canvas-png (path)
  "Write the canvas to PATH as a PNG, a square *CANVAS-PNG-SIZE* points across
at the screen's scale.  Thread 1.

Painted afresh into a renderer's context rather than copied off the view, so
it does not matter whether the canvas is on screen, or ever has been."
  (let* ((size *canvas-png-size*)
         (renderer (objc:invoke (objc:invoke "UIGraphicsImageRenderer" "alloc")
                                "initWithSize:" (vector size size)))
         (failure nil)
         (data nil))
    (objc:with-objc-block (actions 'canvas-drawing-actions
                                   (lambda (context)
                                     (declare (ignore context))
                                     ;; Nothing may unwind into UIKit.
                                     (handler-case (paint-canvas size size)
                                       (error (condition) (setf failure condition)))))
      (setf data (objc:invoke renderer "PNGDataWithActions:" actions)))
    (objc:release renderer)
    (when failure (error failure))
    (unless (and (live-pointer-p data)
                 (objc:invoke-bool data "writeToFile:atomically:" path t))
      (error "The canvas could not be written to ~a." path))
    path))
