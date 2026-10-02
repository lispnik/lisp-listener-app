;;;; src/places.lisp -- places: where a value is, and whether it may be changed.
;;;;
;;;; The inspector shows values, and a value on its own cannot be edited: to
;;;; change the third element of a vector you need the vector and the three.
;;;; A PLACE is that pair, as an object -- Clouseau's idea, and the half of an
;;;; inspector LispWorks' flat table of names and values has no room for.  One
;;;; setter for a whole table cannot say that row 3 is read-only, or that row 5
;;;; takes only an (unsigned-byte 8); a place per row can.
;;;;
;;;; So each place answers for itself: its value, whether it has one (a slot may
;;;; be unbound), what may be done to it (:SET, :REMOVE), and whether a given
;;;; new value is acceptable.  A view hands places to the inspector as the
;;;; cells of a table, and the inspector does the rest -- shows them, lets a
;;;; double click walk into one, and lets a typed value replace one.
;;;;
;;;; The names are the INSPECTOR package's; see src/package.lisp.

(in-package #:lisp-listener)

(defclass inspector:place ()
  ((label :initarg :label :initform nil :reader inspector:place-label
          :documentation "What to call it in the path: a slot's name, [3]."))
  (:documentation "Somewhere a value is kept."))

(defgeneric inspector:place-value (place)
  (:documentation "The value at PLACE."))

(defgeneric (setf inspector:place-value) (value place)
  (:documentation "Put VALUE at PLACE.  Only asked where PLACE-SUPPORTS-P says
:SET and PLACE-ACCEPTS-P has said yes to VALUE."))

(defgeneric inspector:place-bound-p (place)
  (:documentation "Whether there is a value at PLACE at all.")
  (:method ((place inspector:place)) t))

(defgeneric inspector:place-supports-p (place operation)
  (:documentation "Whether OPERATION -- :SET or :REMOVE -- may be done to PLACE.")
  (:method ((place inspector:place) operation)
    (declare (ignore operation))
    nil))

(defgeneric inspector:place-accepts-p (place value)
  (:documentation "Whether VALUE may be put at PLACE.")
  (:method ((place inspector:place) value)
    (declare (ignore value))
    t))

(defgeneric place-remove (place)
  (:documentation "Take the value at PLACE away: unbind the slot, drop the key,
close the gap in a sequence.")
  (:method ((place inspector:place))
    (error "~a cannot be removed." (inspector:place-label place))))

(defgeneric place-insert (place value)
  (:documentation "Put VALUE in just before PLACE, moving PLACE and what is
after it along.  Only where PLACE-SUPPORTS-P says :INSERT.")
  (:method ((place inspector:place) value)
    (declare (ignore value))
    (error "Nothing can be inserted before ~a." (inspector:place-label place))))

;;; A place made of functions --------------------------------------------------------
;;;
;;; The general one, and what a contributor reaches for: (inspector:place :get
;;; ... :set ...).  PLACE is a class and a function both, which Lisp allows.

(defclass function-place (inspector:place)
  ((get :initarg :get)
   (set :initarg :set :initform nil)
   (accepts :initarg :accepts :initform nil)))

(defun inspector:place (&key label get set accepts)
  "A place whose value is whatever GET answers, changed -- if SET is given --
by calling SET with the new value, which ACCEPTS, if given, must first approve.

    (inspector:place :label \"opacity\"
                     :get (lambda () (opacity thing))
                     :set (lambda (v) (setf (opacity thing) v))
                     :accepts (lambda (v) (and (realp v) (<= 0 v 1))))"
  (make-instance 'function-place :label label :get get :set set :accepts accepts))

(defmethod inspector:place-value ((place function-place))
  (funcall (slot-value place 'get)))

(defmethod (setf inspector:place-value) (value (place function-place))
  (funcall (slot-value place 'set) value)
  value)

(defmethod inspector:place-supports-p ((place function-place) operation)
  (and (eq operation :set) (slot-value place 'set) t))

(defmethod inspector:place-accepts-p ((place function-place) value)
  (let ((accepts (slot-value place 'accepts)))
    (or (null accepts) (and (funcall accepts value) t))))

(defun inspector:value (value &optional label)
  "A place that only holds VALUE: something to show, and to walk into, that
cannot be changed.  What a computed row of a table is."
  (make-instance 'function-place :label label :get (lambda () value)))

;;; A slot ---------------------------------------------------------------------------

(defclass inspector:slot-place (inspector:place)
  ((object :initarg :object)
   (name :initarg :name)))

(defun inspector:slot-place (object slot-name)
  "The slot SLOT-NAME of OBJECT, a standard object or a structure."
  (make-instance 'inspector:slot-place :object object :name slot-name
                                       :label (string-downcase slot-name)))

(defmethod inspector:place-value ((place inspector:slot-place))
  (with-slots (object name) place
    (slot-value object name)))

(defmethod (setf inspector:place-value) (value (place inspector:slot-place))
  (with-slots (object name) place
    (setf (slot-value object name) value)))

(defmethod inspector:place-bound-p ((place inspector:slot-place))
  (with-slots (object name) place
    (handler-case (slot-boundp object name)
      ;; A structure's slot is always bound, and some Lisps will not be asked.
      (error () t))))

(defmethod inspector:place-supports-p ((place inspector:slot-place) operation)
  (with-slots (object) place
    (case operation
      (:set t)
      (:remove (typep object 'standard-object)))))

(defmethod place-remove ((place inspector:slot-place))
  (with-slots (object name) place
    (slot-makunbound object name)))

;;; An element of a sequence, or of an array ----------------------------------------

(defun element-type-accepts-p (array value)
  (typep value (array-element-type array)))

(defclass inspector:element-place (inspector:place)
  ((sequence :initarg :sequence)
   (index :initarg :index)))

(defun inspector:element-place (sequence index)
  "Element INDEX of SEQUENCE, a list or a vector."
  (make-instance 'inspector:element-place :sequence sequence :index index
                                          :label (format nil "[~d]" index)))

(defmethod inspector:place-value ((place inspector:element-place))
  (with-slots (sequence index) place
    (elt sequence index)))

(defmethod (setf inspector:place-value) (value (place inspector:element-place))
  (with-slots (sequence index) place
    (setf (elt sequence index) value)))

(defun growable-vector-p (object)
  (and (vectorp object) (array-has-fill-pointer-p object) (adjustable-array-p object)))

(defmethod inspector:place-supports-p ((place inspector:element-place) operation)
  ;; Any element can be set.  One can be taken out, or another put in before
  ;; it, only where the sequence can change its length: a vector with a fill
  ;; pointer that may be adjusted.
  (with-slots (sequence) place
    (case operation
      (:set t)
      ((:remove :insert) (growable-vector-p sequence)))))

(defmethod place-remove ((place inspector:element-place))
  (with-slots (sequence index) place
    (replace sequence sequence :start1 index :start2 (1+ index))
    (decf (fill-pointer sequence))))

(defmethod place-insert ((place inspector:element-place) value)
  (with-slots (sequence index) place
    (unless (element-type-accepts-p sequence value)
      (error "That is not something this vector can hold."))
    (vector-push-extend value sequence)
    (replace sequence sequence :start1 (1+ index) :start2 index
                               :end2 (1- (length sequence)))
    (setf (aref sequence index) value)))

;;; An element of a list.  A place of its own, because a list changes length
;;; by changing its conses: what is done here is done IN PLACE, so that the
;;; list being inspected -- its first cons -- is still the list afterwards.
;;; That is why the only element of a list cannot be removed: what would be
;;; left is NIL, which is not that cons.

(defclass list-element-place (inspector:place)
  ((list :initarg :list)
   (index :initarg :index)))

(defun list-element-place (list index)
  (make-instance 'list-element-place :list list :index index
                                     :label (format nil "[~d]" index)))

(defmethod inspector:place-value ((place list-element-place))
  (with-slots (list index) place
    (nth index list)))

(defmethod (setf inspector:place-value) (value (place list-element-place))
  (with-slots (list index) place
    (setf (nth index list) value)))

(defmethod inspector:place-supports-p ((place list-element-place) operation)
  (with-slots (list) place
    (case operation
      ((:set :insert) t)
      (:remove (and (cdr list) t)))))

(defmethod place-remove ((place list-element-place))
  (with-slots (list index) place
    (if (zerop index)
        ;; The first cons stays, and takes over the second's contents.
        (setf (car list) (cadr list)
              (cdr list) (cddr list))
        (let ((before (nthcdr (1- index) list)))
          (setf (cdr before) (cddr before))))))

(defmethod place-insert ((place list-element-place) value)
  (with-slots (list index) place
    (let ((cons (nthcdr index list)))
      ;; A new cons AFTER this one holding what this one held, and the new
      ;; value in this one: the same as inserting before it, with no need for
      ;; the cons in front -- which the first has not got.
      (setf (cdr cons) (cons (car cons) (cdr cons))
            (car cons) value))))

(defmethod inspector:place-accepts-p ((place inspector:element-place) value)
  (with-slots (sequence) place
    (or (listp sequence) (element-type-accepts-p sequence value))))

(defclass inspector:aref-place (inspector:place)
  ((array :initarg :array)
   (index :initarg :index)))

(defun inspector:aref-place (array &rest subscripts)
  "The element of ARRAY at SUBSCRIPTS."
  (make-instance 'inspector:aref-place
                 :array array
                 :index (apply #'array-row-major-index array subscripts)
                 :label (format nil "[~{~d~^ ~}]" subscripts)))

(defmethod inspector:place-value ((place inspector:aref-place))
  (with-slots (array index) place
    (row-major-aref array index)))

(defmethod (setf inspector:place-value) (value (place inspector:aref-place))
  (with-slots (array index) place
    (setf (row-major-aref array index) value)))

(defmethod inspector:place-supports-p ((place inspector:aref-place) operation)
  (eq operation :set))

(defmethod inspector:place-accepts-p ((place inspector:aref-place) value)
  (element-type-accepts-p (slot-value place 'array) value))

;;; A hash table's value -------------------------------------------------------------

(defclass inspector:hash-place (inspector:place)
  ((table :initarg :table)
   (key :initarg :key)))

(defun inspector:hash-place (table key)
  "The value under KEY in the hash table TABLE."
  (make-instance 'inspector:hash-place
                 :table table :key key
                 :label (let ((*print-length* 4) (*print-level* 2))
                          (handler-case (prin1-to-string key)
                            (error () "key")))))

(defmethod inspector:place-value ((place inspector:hash-place))
  (with-slots (table key) place
    (values (gethash key table))))

(defmethod (setf inspector:place-value) (value (place inspector:hash-place))
  (with-slots (table key) place
    (setf (gethash key table) value)))

(defmethod inspector:place-bound-p ((place inspector:hash-place))
  (with-slots (table key) place
    (nth-value 1 (gethash key table))))

(defmethod inspector:place-supports-p ((place inspector:hash-place) operation)
  (member operation '(:set :remove)))

(defmethod place-remove ((place inspector:hash-place))
  (with-slots (table key) place
    (remhash key table)))

;;; Adding to a collection -----------------------------------------------------------
;;;
;;; A place is somewhere a value already is.  Putting a NEW thing into a
;;; collection is not a place's business but the collection's: a hash table
;;; takes a key and a value, a list or a growable vector takes a value.  Two
;;; generic functions say so, and a collection of your own can join in.

(defgeneric inspector:addition (object)
  (:documentation "What can be added to OBJECT through the inspector: NIL for
nothing, :VALUE for an element, :KEY-AND-VALUE for an entry under a key.")
  (:method ((object t)) nil)
  (:method ((object hash-table)) :key-and-value)
  ;; A proper list only: the new element goes on the END, destructively, so
  ;; that the list being inspected is still the list.  Pushing onto the front
  ;; would make a new list and leave this one as it was.
  (:method ((object cons))
    (and (ignore-errors (list-length object)) (null (cdr (last object))) :value))
  (:method ((object vector))
    (and (array-has-fill-pointer-p object) (adjustable-array-p object) :value)))

(defgeneric inspector:add (object value &optional key)
  (:documentation "Add VALUE to OBJECT -- under KEY, where its ADDITION is
:KEY-AND-VALUE.")
  (:method ((object hash-table) value &optional key)
    (setf (gethash key object) value))
  (:method ((object cons) value &optional key)
    (declare (ignore key))
    (setf (cdr (last object)) (list value))
    value)
  (:method ((object vector) value &optional key)
    (declare (ignore key))
    (unless (typep value (array-element-type object))
      (error "~a is not something this vector can hold."
             (let ((*print-length* 4) (*print-level* 2)) (prin1-to-string value))))
    (vector-push-extend value object)
    value))

;;; An Objective-C object ------------------------------------------------------------
;;;
;;; A foreign pointer has no type that says what it points at.  Whether it is
;;; an Objective-C object can only be found out by sending it a message, and a
;;; message sent to something that is not one -- a malloc'd buffer, a C struct
;;; -- does not signal an error: it takes the process down.  So the inspector
;;; never asks.  A pointer on its own is shown as an address and nothing more;
;;; it is treated as an object only when somebody has SAID it is one, by
;;; wrapping it: (inspector:objc pointer), or the button on a pointer's view.

(defstruct (objc-object (:constructor %make-objc-object (pointer)))
  pointer)

(defun inspector:objc (pointer)
  "Say that POINTER is an Objective-C object, so that the inspector may treat
it as one: ask its class, and show the views that apply to that class.

    (inspect (inspector:objc (objc:invoke \"NSDate\" \"date\")))

You are vouching for it.  A pointer that is not an object, wrapped and
inspected, will crash the program the first time it is sent a message."
  (cond ((objc-object-p pointer) pointer)
        ((and (cffi:pointerp pointer) (not (cffi:null-pointer-p pointer)))
         (%make-objc-object pointer))
        (t (error "~s is not a pointer to an Objective-C object." pointer))))

(defun inspector:objc-pointer (object)
  "The pointer inside OBJECT, which INSPECTOR:OBJC made."
  (objc-object-pointer object))

(defun objc-class-name-of (object)
  "The name of OBJECT's class, or NIL if it will not say."
  (ignore-errors
   (objc:ns-string-to-string
    (objc:invoke (objc:invoke (objc-object-pointer object) "class") "description"))))

(defun objc-kind-of-p (object class-name)
  "Whether OBJECT, an OBJC-OBJECT, is an instance of the class called
CLASS-NAME or of a subclass.  NIL for anything else, and for a class that is
not loaded."
  (and (objc-object-p object)
       (ignore-errors
        (objc:invoke-bool (objc-object-pointer object) "isKindOfClass:"
                          (objc:coerce-to-objc-class class-name)))))

(defmethod print-object ((object objc-object) stream)
  (print-unreadable-object (object stream)
    (format stream "ObjC ~a ~x"
            (or (objc-class-name-of object) "object")
            (ignore-errors (cffi:pointer-address (objc-object-pointer object))))))
