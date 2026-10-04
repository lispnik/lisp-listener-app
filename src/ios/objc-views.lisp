;;;; src/ios/objc-views.lisp -- views of UIKit's objects.
;;;;
;;;; The ones that need UIKit to be shown at all, as src/macos/objc-views.lisp
;;;; has AppKit's: each answers a NATIVE scene -- a function that makes a
;;;; UIView, on thread 1 -- and says :REQUIRES (:UIKIT).  An image; a view, a
;;;; window and a view controller as they draw themselves now; and a slider on
;;;; a view's opacity.
;;;;
;;;;     (inspect (inspector:objc (uikit:key-window)))
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

(defun make-ui-image-view (image)
  "A UIImageView showing IMAGE, scaled to fit.  Autoreleased."
  (let ((view (objc:invoke (objc:invoke "UIImageView" "alloc") "initWithImage:" image)))
    (objc:invoke view "setContentMode:" 1)       ; UIViewContentModeScaleAspectFit
    (objc:autorelease view)))

(defun ui-view-picture (view)
  "A UIImage of VIEW as it draws itself now -- its subviews included -- painted
into a renderer's context, as (save \"x.png\") paints the canvas.  The
renderer's block is the canvas's block type: a function of the context."
  (let* ((bounds (objc:invoke view "bounds"))
         (renderer (objc:invoke (objc:invoke "UIGraphicsImageRenderer" "alloc")
                                "initWithBounds:" bounds))
         (image nil))
    (objc:with-objc-block (actions 'canvas-drawing-actions
                                   (lambda (context)
                                     (declare (ignore context))
                                     (handler-case
                                         (objc:invoke view "drawViewHierarchyInRect:afterScreenUpdates:"
                                                      bounds nil)
                                       (error (condition) (note "a view's picture: ~a" condition)))))
      (setf image (objc:invoke renderer "imageWithActions:" actions)))
    (objc:release renderer)
    image))

(defun view-picture-scene (view what)
  (let ((bounds (objc:invoke view "bounds")))
    (inspector:native
     (lambda () (make-ui-image-view (ui-view-picture view)))
     :fallback (inspector:text "~a, ~d by ~d points." what
                               (round (aref bounds 2)) (round (aref bounds 3))))))

(inspector:define-view (ui-view-picture-view :title "Picture" :objc-class "UIView"
                                             :priority 20 :requires (:uikit))
    (object)
  "A UIView -- a window, a button, the transcript -- as it draws itself now."
  (view-picture-scene (inspector:objc-pointer object) "A view"))

(inspector:define-view (ui-controller-picture-view :title "Picture"
                                                   :objc-class "UIViewController"
                                                   :priority 20 :requires (:uikit))
    (object)
  "A view controller, as its view draws itself now."
  (view-picture-scene (objc:invoke (inspector:objc-pointer object) "view")
                      "A view controller's view"))

(inspector:define-view (ui-controller-view-view :title "View" :objc-class "UIViewController"
                                                :priority 10)
    (object)
  "A view controller's view, and what it has presented, to walk into."
  (let ((controller (inspector:objc-pointer object)))
    (inspector:table
     :columns '("" "")
     :rows (list (list "view" (inspector:value (objc-value (objc:invoke controller "view"))))
                 (list "presented"
                       (inspector:value
                        (objc-value (objc:invoke controller "presentedViewController"))))))))
