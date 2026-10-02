;;;; src/macos/objc-views.lisp -- views of AppKit's objects.
;;;;
;;;; The ones that need AppKit to be shown at all: an image, a picture of a
;;;; view.  Each answers a NATIVE scene -- a function that makes an NSView, on
;;;; thread 1 -- and says :REQUIRES (:APPKIT), so that it is not offered where
;;;; there is no AppKit to show it.  And controls for a window, which are the
;;;; shortest answer to "can a view change the thing?": a slider on its opacity.
;;;;
;;;; Foundation's objects are src/objc-views.lisp.

(in-package #:lisp-listener)

(defun make-image-view (image)
  "An NSImageView showing IMAGE, scaled to fit whatever room it is given.
Autoreleased."
  (let ((view (objc:invoke (objc:invoke "NSImageView" "alloc") "initWithFrame:"
                           (vector 0d0 0d0 240d0 240d0))))
    (objc:invoke view "setImage:" image)
    (objc:invoke view "setImageScaling:" 3)   ; NSImageScaleProportionallyUpOrDown
    (objc:autorelease view)))

(defun view-picture (view)
  "An NSImage of VIEW as it draws itself now.  Autoreleased."
  (let* ((bounds (objc:invoke view "bounds"))
         (representation (objc:invoke view "bitmapImageRepForCachingDisplayInRect:" bounds))
         (image (objc:invoke (objc:invoke "NSImage" "alloc") "initWithSize:"
                             (vector (aref bounds 2) (aref bounds 3)))))
    (objc:invoke view "cacheDisplayInRect:toBitmapImageRep:" bounds representation)
    (objc:invoke image "addRepresentation:" representation)
    (objc:autorelease image)))

(inspector:define-view (objc-image-view :title "Image" :objc-class "NSImage"
                                        :priority 20 :requires (:appkit))
    (object)
  "An NSImage, as a picture."
  (let* ((image (inspector:objc-pointer object))
         (size (objc:invoke image "size")))
    (inspector:native
     (lambda () (make-image-view image))
     :fallback (inspector:text "An image, ~d by ~d points."
                               (round (aref size 0)) (round (aref size 1))))))

(inspector:define-view (objc-view-picture :title "Picture" :objc-class "NSView"
                                          :priority 20 :requires (:appkit))
    (object)
  "An NSView, as it draws itself now."
  (let* ((view (inspector:objc-pointer object))
         (bounds (objc:invoke view "bounds")))
    (inspector:native
     (lambda () (make-image-view (view-picture view)))
     :fallback (inspector:text "A view, ~d by ~d points."
                               (round (aref bounds 2)) (round (aref bounds 3))))))

(inspector:define-view (objc-window-picture :title "Picture" :objc-class "NSWindow"
                                            :priority 20 :requires (:appkit))
    (object)
  "An NSWindow, title bar and all, as it draws itself now."
  (let ((window (inspector:objc-pointer object)))
    (inspector:native
     (lambda () (make-image-view (view-picture (window-capture-view window))))
     :fallback (inspector:text "A window titled ~s."
                               (objc:ns-string-to-string (objc:invoke window "title"))))))

(inspector:define-controls (objc-window-controls :title "Window" :objc-class "NSWindow")
    (object)
  (let ((window (inspector:objc-pointer object)))
    (list (inspector:slider "Opacity"
                            (inspector:place
                             :label "opacity"
                             :get (lambda () (objc:invoke window "alphaValue"))
                             :set (lambda (value)
                                    (objc:invoke window "setAlphaValue:" (float value 1d0)))
                             :accepts (lambda (value) (and (realp value) (<= 0.2 value 1))))
                            :min 0.2 :max 1)
          (inspector:field "Title"
                           (inspector:place
                            :label "title"
                            :get (lambda ()
                                   (objc:ns-string-to-string (objc:invoke window "title")))
                            :set (lambda (value) (objc:invoke window "setTitle:" value))
                            :accepts #'stringp)))))
