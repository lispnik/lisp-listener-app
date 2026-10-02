;;;; src/ios/objc-views.lisp -- views of UIKit's objects.
;;;;
;;;; The ones that need UIKit to be shown at all, as src/macos/objc-views.lisp
;;;; has AppKit's: each answers a NATIVE scene -- a function that makes a
;;;; UIView, on thread 1 -- and says :REQUIRES (:UIKIT).
;;;;
;;;; Foundation's objects are src/objc-views.lisp.

(in-package #:lisp-listener)

(inspector:define-view (objc-image-view :title "Image" :objc-class "UIImage"
                                        :priority 20 :requires (:uikit))
    (object)
  "A UIImage, as a picture."
  (let* ((image (inspector:objc-pointer object))
         (size (objc:invoke image "size")))
    (inspector:native
     (lambda ()
       (let ((view (objc:invoke (objc:invoke "UIImageView" "alloc") "initWithImage:" image)))
         (objc:invoke view "setContentMode:" 1) ; UIViewContentModeScaleAspectFit
         (objc:autorelease view)))
     :fallback (inspector:text "An image, ~d by ~d points."
                               (round (aref size 0)) (round (aref size 1))))))

(inspector:define-controls (objc-view-controls :title "View" :objc-class "UIView")
    (object)
  (let ((view (inspector:objc-pointer object)))
    (list (inspector:slider "Opacity"
                            (inspector:place
                             :label "opacity"
                             :get (lambda () (objc:invoke view "alpha"))
                             :set (lambda (value)
                                    (objc:invoke view "setAlpha:" (float value 1d0)))
                             :accepts (lambda (value) (and (realp value) (<= 0.2 value 1))))
                            :min 0.2 :max 1))))
