;;;; src/macos/canvas-window.lisp -- the canvas, as a window beside the listener.
;;;;
;;;; The Mac's half of src/canvas.lisp: an NSView whose -drawRect: is
;;;; PAINT-CANVAS, in a window of its own.  There is one canvas however many
;;;; listeners there are; it is made the first time anything is drawn, and
;;;; drawing brings it back if it was closed.
;;;;
;;;; Drawing shows the window but leaves the keyboard at the prompt, because
;;;; that is where the next form is about to be typed.  (show) is what gives the
;;;; canvas the keyboard, and a game calls it.
;;;;
;;;; Thread 1, all of it.

(in-package #:lisp-listener)

(defparameter *canvas-window-size* 480d0)

(defvar *canvas-window* nil
  "The canvas's NSWindow, or NIL before anything has been drawn.  Made at run
time, like everything foreign: NIL is what a dumped core starts with.")

(defvar *canvas-view* nil
  "The Lisp object behind the canvas's view, held so that it stays.")

(defun canvas-toolkit () :appkit)

;;; The view --------------------------------------------------------------------

(objc:define-objc-class canvas-view ()
  ()
  (:objc-class-name "LispListenerCanvasView")
  (:objc-superclass-name "NSView"))

;;; Flipped, so that one painter does for this and for UIKit, where y runs down
;;; whether one likes it or not.  CANVAS-DEVICE-OPS turns the canvas's own
;;; upward y over.
(objc:define-objc-method ("isFlipped" objc:objc-bool)
    ((self canvas-view))
  t)

(objc:define-objc-method ("acceptsFirstResponder" objc:objc-bool)
    ((self canvas-view))
  t)

(objc:define-objc-method ("drawRect:" :void)
    ((self canvas-view pointer) (dirty cocoa:ns-rect))
  (declare (ignorable dirty))
  ;; Nothing may unwind into AppKit.
  (handler-case
      (let ((bounds (objc:invoke pointer "bounds")))
        (paint-canvas (aref bounds 2) (aref bounds 3)))
    (error (condition) (note "canvas drawRect: ~a" condition))))

(objc:define-objc-method ("keyDown:" :void)
    ((self canvas-view) (event objc:objc-object-pointer))
  ;; Every key is the canvas's, and super is not called: an NSView with nothing
  ;; to do with a key passes it up the chain until something beeps.  Command
  ;; keys never get here -- the menu has them first.
  (handler-case
      (let ((characters (objc:ns-string-to-string
                         (objc:invoke event "charactersIgnoringModifiers"))))
        (when (plusp (length characters))
          (canvas-push-key (canvas-key-for-character (char characters 0)))))
    (error (condition) (note "canvas keyDown: ~a" condition))))

;;; The mouse is the canvas's pointer: (pointer) answers where it is and
;;; whether the button is down, and a press is the key :CLICK.  Positions are
;;; the view's own, which is flipped like the painter's.
(defun canvas-mouse-event (pointer event phase)
  (let ((point (objc:invoke pointer "convertPoint:fromView:"
                            (objc:invoke event "locationInWindow") nil))
        (bounds (objc:invoke pointer "bounds")))
    (canvas-pointer-event phase (aref point 0) (aref point 1)
                          (aref bounds 2) (aref bounds 3))))

(objc:define-objc-method ("mouseDown:" :void)
    ((self canvas-view pointer) (event objc:objc-object-pointer))
  (handler-case (canvas-mouse-event pointer event :down)
    (error (condition) (note "canvas mouseDown: ~a" condition))))

(objc:define-objc-method ("mouseDragged:" :void)
    ((self canvas-view pointer) (event objc:objc-object-pointer))
  (handler-case (canvas-mouse-event pointer event :move)
    (error (condition) (note "canvas mouseDragged: ~a" condition))))

;;; Without a button down, too: (pointer) follows the mouse.  AppKit sends
;;; -mouseMoved: only to a view with a tracking area that asks for it; see
;;; BUILD-CANVAS-WINDOW.  :MOVE keeps whatever "down" was, which here is up.
(objc:define-objc-method ("mouseMoved:" :void)
    ((self canvas-view pointer) (event objc:objc-object-pointer))
  (handler-case (canvas-mouse-event pointer event :move)
    (error (condition) (note "canvas mouseMoved: ~a" condition))))

(objc:define-objc-method ("mouseUp:" :void)
    ((self canvas-view pointer) (event objc:objc-object-pointer))
  (handler-case (canvas-mouse-event pointer event :up)
    (error (condition) (note "canvas mouseUp: ~a" condition))))

;;; The click that brings the canvas's window forward is a click on the canvas
;;; as well: drawing shows the window without making it key, so the first
;;; press would otherwise be spent on waking it.
(objc:define-objc-method ("acceptsFirstMouse:" objc:objc-bool)
    ((self canvas-view) (event objc:objc-object-pointer))
  (declare (ignorable event))
  t)

;;; The view is its window's delegate too, to hear that it was closed.
(objc:define-objc-method ("windowWillClose:" :void)
    ((self canvas-view) (notification objc:objc-object-pointer))
  (declare (ignorable notification))
  (handler-case (canvas-closed-by-person)
    (error (condition) (note "canvas windowWillClose: ~a" condition))))

;;; The window ------------------------------------------------------------------

(defun place-canvas-window (window)
  "Beside the front listener's window, top edges level, if the screen has the
room; against the screen's right edge if it has not."
  (let* ((listener (current-listener))
         (beside (and listener (listener-window listener)))
         (screen (and (live-pointer-p beside) (objc:invoke beside "screen"))))
    (if (live-pointer-p screen)
        (let* ((frame (objc:invoke beside "frame"))
               (visible (objc:invoke screen "visibleFrame"))
               (right (+ (aref visible 0) (aref visible 2)))
               (x (min (+ (aref frame 0) (aref frame 2) 12d0)
                       (- right *canvas-window-size* 12d0))))
          (objc:invoke window "setFrameTopLeftPoint:"
                       (vector (max x (aref visible 0))
                               (+ (aref frame 1) (aref frame 3)))))
        (objc:invoke window "center"))))

(defun build-canvas-window ()
  (let* ((frame (vector 0d0 0d0 *canvas-window-size* *canvas-window-size*))
         (object (make-instance 'canvas-view
                                :init-function
                                (lambda (pointer &rest initargs)
                                  (declare (ignore initargs))
                                  (objc:invoke pointer "initWithFrame:" frame))
                                :allow-other-keys t))
         (view (objc:objc-object-pointer object))
         (window (objc:invoke (objc:invoke "NSWindow" "alloc")
                              "initWithContentRect:styleMask:backing:defer:"
                              frame +ns-window-style-mask+
                              +ns-backing-store-buffered+ nil)))
    ;; Lisp owns it, as it owns the listener's; see MAKE-LISTENER-WINDOW.
    (objc:invoke window "setReleasedWhenClosed:" nil)
    (objc:invoke window "setTitle:" "Canvas")
    (objc:invoke view "setAutoresizingMask:" +ns-view-width-and-height-sizable+)
    (objc:invoke window "setContentView:" view)
    (objc:invoke window "setInitialFirstResponder:" view)
    (objc:invoke window "setDelegate:" view)
    ;; For -mouseMoved:.  NSTrackingMouseMoved (2); NSTrackingActiveAlways
    ;; (#x80), because drawing shows this window without making it key, and a
    ;; program following the mouse should not need a click first; and
    ;; NSTrackingInVisibleRect (#x200), so that the area is the view at any size.
    (let ((area (objc:invoke (objc:invoke "NSTrackingArea" "alloc")
                             "initWithRect:options:owner:userInfo:"
                             frame (logior #x02 #x80 #x200) view nil)))
      (objc:invoke view "addTrackingArea:" area)
      (objc:release area))
    ;; Where it was last time, if that is remembered and still on a screen.
    (unless (and *reopen-windows*
                 (set-window-frame window (remembered :canvas)))
      (place-canvas-window window))
    (setf *canvas-view* object
          *canvas-window* window)))

(defun canvas-view-pointer ()
  (and *canvas-view* (objc:objc-object-pointer *canvas-view*)))

(defun canvas-visible-p ()
  (and (live-pointer-p *canvas-window*)
       (objc:invoke-bool *canvas-window* "isVisible")))

(defun show-canvas (&key keyboard)
  "Put the canvas on screen.  With KEYBOARD it becomes the key window, which is
what a game wants; without, it comes forward and the prompt keeps the keys."
  (unless (live-pointer-p *canvas-window*)
    (build-canvas-window))
  (let ((window *canvas-window*))
    (cond (keyboard
           (objc:invoke window "makeKeyAndOrderFront:" nil)
           (objc:invoke window "makeFirstResponder:" (canvas-view-pointer)))
          ((not (canvas-visible-p))
           (objc:invoke window "orderFront:" nil))))
  t)

(defun hide-canvas ()
  "Close the canvas window.  What was drawn is kept, and drawing reopens it."
  (when (canvas-visible-p)
    (objc:invoke *canvas-window* "close"))
  t)

(defun redisplay-canvas ()
  "Repaint, showing the window first if it is not up."
  (show-canvas)
  (objc:invoke (canvas-view-pointer) "setNeedsDisplay:" t)
  t)

(defun documents-directory ()
  "Where (save \"name.png\") puts a file that names no directory: ~/Pictures.
Not the Desktop or Documents, which macOS asks permission for."
  (merge-pathnames "Pictures/" (user-homedir-pathname)))

(defun download-directory ()
  "Where (download url) puts a file that names no directory: ~/Downloads."
  (merge-pathnames "Downloads/" (user-homedir-pathname)))

(defun save-canvas-png (path)
  "Write the canvas, as its view paints it, to PATH.  Thread 1.

The view draws itself into a bitmap, as the screenshots do, so the window need
not be on screen -- nor ever have been: it is made here if it was not."
  (unless (live-pointer-p *canvas-window*)
    (build-canvas-window))
  (let* ((view (canvas-view-pointer))
         (bounds (objc:invoke view "bounds"))
         (representation (objc:invoke view "bitmapImageRepForCachingDisplayInRect:" bounds)))
    (objc:invoke view "cacheDisplayInRect:toBitmapImageRep:" bounds representation)
    (unless (objc:invoke-bool
             (objc:invoke representation "representationUsingType:properties:"
                          +png-file-type+ (objc:invoke "NSDictionary" "dictionary"))
             "writeToFile:atomically:" path t)
      (error "The canvas could not be written to ~a." path))
    path))

(defun remember-canvas-window ()
  "Record where the canvas's window is, if there is one.  Not saved here:
REMEMBER-WINDOWS writes the file once for everything."
  (when (live-pointer-p *canvas-window*)
    (setf (getf *remembered* :canvas) (window-frame-list *canvas-window*))))
