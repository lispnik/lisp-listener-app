;;;; src/objc-views.lisp -- views of Objective-C objects.
;;;;
;;;; For a pointer somebody has vouched for (INSPECTOR:OBJC, in src/places.lisp;
;;;; a pointer on its own is never asked anything).  Matched by :OBJC-CLASS,
;;;; which is `-isKindOfClass:', and run on thread 1, where the inspector does
;;;; everything for such an object: AppKit and UIKit want theirs touched there
;;;; and nowhere else.
;;;;
;;;; These are Foundation's, the same on the Mac and on iOS.  What needs a
;;;; toolkit -- an image, a view -- is the front end's: src/macos/objc-views.lisp.
;;;;
;;;; A value that comes OUT of an Objective-C collection is an object too, by
;;;; the collection's own contract, and is wrapped on the way: so an array's
;;;; elements can be walked into, and theirs.

(in-package #:lisp-listener)

(defun objc-description (pointer &optional (limit 400))
  "What POINTER says of itself, on one line and within reason."
  (clip-string (or (ignore-errors
                    (objc:ns-string-to-string (objc:invoke pointer "description")))
                   "?")
               limit))

(defun objc-superclass-names (pointer)
  "The names of POINTER's class and its superclasses, most specific first."
  (loop for class = (objc:invoke pointer "class") then (objc:invoke class "superclass")
        while (and (cffi:pointerp class) (not (cffi:null-pointer-p class)))
        collect (objc:ns-string-to-string (objc:invoke class "description"))))

(defun objc-value (pointer)
  "POINTER, an object out of an Objective-C collection, as something to show
and walk into: wrapped, or NIL for nil."
  (and (cffi:pointerp pointer) (not (cffi:null-pointer-p pointer))
       (inspector:objc pointer)))

(inspector:define-view (objc-object-view :title "Objective-C" :objc-class "NSObject"
                                         :priority 5)
    (object)
  "An Objective-C object: its class, where that comes from, and what it says
of itself."
  (let ((pointer (inspector:objc-pointer object)))
    (inspector:table
     :columns '("" "")
     :rows (list (list "class" (or (objc-class-name-of object) "?"))
                 (list "inherits from"
                       (format nil "~{~a~^ : ~}" (rest (objc-superclass-names pointer))))
                 (list "description" (objc-description pointer))
                 (list "address" (format nil "#x~x" (cffi:pointer-address pointer)))))))

(inspector:define-view (objc-array-view :title "Elements" :objc-class "NSArray"
                                        :priority 10)
    (object)
  "An NSArray's elements."
  (let ((array (inspector:objc-pointer object)))
    (inspector:table
     :columns '("Index" "Value")
     :count (objc:invoke array "count")
     :row (lambda (index)
            (list (format nil "[~d]" index)
                  (inspector:value (objc-value (objc:invoke array "objectAtIndex:" index))
                                   (format nil "[~d]" index)))))))

(inspector:define-view (objc-dictionary-view :title "Entries" :objc-class "NSDictionary"
                                             :priority 10)
    (object)
  "An NSDictionary's keys and values."
  (let* ((dictionary (inspector:objc-pointer object))
         (keys (objc:invoke dictionary "allKeys")))
    (inspector:table
     :columns '("Key" "Value")
     :count (objc:invoke keys "count")
     :row (lambda (index)
            (let ((key (objc:invoke keys "objectAtIndex:" index)))
              (list (inspector:value (objc-value key))
                    (inspector:value (objc-value (objc:invoke dictionary "objectForKey:" key))
                                     (objc-description key 30))))))))

(inspector:define-view (objc-string-view :title "Text" :objc-class "NSString" :priority 10)
    (object)
  "An NSString, as what it says."
  (inspector:text "~a" (objc:ns-string-to-string (inspector:objc-pointer object))))

;;; A view's subviews, to walk down the hierarchy a row at a time.  Twice, once
;;; for each toolkit's class: a class the platform has not got simply matches
;;; nothing (OBJC-KIND-OF-P asks NSClassFromString, which answers nil).

(defun subviews-scene (object)
  (let ((subviews (objc:invoke (inspector:objc-pointer object) "subviews")))
    (inspector:table
     :columns '("Index" "Subview")
     :count (objc:invoke subviews "count")
     :row (lambda (index)
            (let ((subview (objc:invoke subviews "objectAtIndex:" index)))
              (list (format nil "[~d]" index)
                    (inspector:value (objc-value subview)
                                     (or (objc-class-name-of (objc-value subview))
                                         (format nil "[~d]" index)))))))))

(inspector:define-view (ns-subviews-view :title "Subviews" :objc-class "NSView" :priority 8)
    (object)
  "An NSView's subviews, each one to walk into."
  (subviews-scene object))

(inspector:define-view (ui-subviews-view :title "Subviews" :objc-class "UIView" :priority 8)
    (object)
  "A UIView's subviews, each one to walk into -- a window's included."
  (subviews-scene object))
