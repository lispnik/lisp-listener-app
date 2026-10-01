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
    (place-canvas-window window)
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
