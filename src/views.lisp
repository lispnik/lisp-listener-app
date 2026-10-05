;;;; src/views.lisp -- views anybody can contribute, and the scenes they answer.
;;;;
;;;; An inspector that only its author can teach is a table of slots for ever.
;;;; So a VIEW here is something any loaded system may add:
;;;;
;;;;     (inspector:define-view (histogram :title "Histogram"
;;;;                                       :type (vector (unsigned-byte 8))
;;;;                                       :options ((bins 32 :integer :min 4 :max 256)))
;;;;         (bytes &key bins)
;;;;       (inspector:drawing () ...))
;;;;
;;;; and it is offered for every object it applies to -- by TYPE, a type
;;;; specifier, and optionally by WHEN, a predicate, for what a type cannot say.
;;;; Several apply to most things, and two can be open side by side: a byte
;;;; vector as a histogram and as hex.
;;;;
;;;; A VIEW DOES NOT DRAW.  It answers a SCENE, which is data: a table of
;;;; places, some text, a drawing made of the canvas's shapes, or a stack of
;;;; those.  That is LispWorks' contract rather than Clouseau's, whose views
;;;; write CLIM output and so can be shown by nothing else.  Data can be put in
;;;; a window, printed in a transcript, or asserted on by `make test', and the
;;;; view cannot tell which.
;;;;
;;;; Two things a view may have that are easy to confuse and are kept apart:
;;;;
;;;;   OPTIONS are the view's own -- how many bins, which colours.  They change
;;;;   the picture and nothing else, and are declared as data so that a front
;;;;   end can make controls for them without knowing the view.
;;;;
;;;;   CONTROLS belong to the OBJECT -- a slider on a slot.  They are bound to
;;;;   places, they change the thing inspected, and DEFINE-CONTROLS contributes
;;;;   them separately, since the system that knows how to draw a thing and the
;;;;   one that knows what may be changed about it need not be the same.

(in-package #:lisp-listener)

;;; The time a view may take --------------------------------------------------------
;;;
;;; Here, ahead of the first thing that is timed.  The thread that does the
;;; timing, and the rest of the worker, are in src/inspector.lisp.

(defvar *inspector-worker* nil
  "The inspector's worker thread, once there is one.")

;;; A view is somebody else's code, and may never return.  Everything of
;;; somebody else's that the worker runs -- a view, a row, a place, a control
;;; -- runs inside WITH-TIME-LIMIT, and a second thread, the watchdog, looks
;;; four times a second at how long the worker has been in there.  Past the
;;; limit it interrupts the worker with an error, which the handler already
;;; around the call turns into "took too long" in place of the view.  One
;;; view that hangs is then one pane that says so, and not every inspector in
;;; the program waiting behind it for ever.

(defparameter *inspector-time-limit* 5
  "Seconds a view, a row or a place may take before it is stopped.")

(define-condition inspector-timeout (error) ()
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (format stream "It took more than ~d second~:p, and was stopped."
                     *inspector-time-limit*))))

(defvar *inspector-timed* nil
  "While the worker is inside WITH-TIME-LIMIT: (TOKEN . START), TOKEN a fresh
cons that says WHICH time it is in there, so that an interrupt sent for one
piece of work cannot land on the next.")

(defun call-with-time-limit (function)
  (if (and *inspector-worker* (eq (bt:current-thread) *inspector-worker*))
      (unwind-protect
           (progn (setf *inspector-timed* (cons (list nil) (get-internal-real-time)))
                  (funcall function))
        (setf *inspector-timed* nil))
      ;; Not the worker: under `make test', or on thread 1 for an Objective-C
      ;; object.  Nobody is watching, and thread 1 is not for interrupting.
      (funcall function)))

(defmacro with-time-limit (() &body body)
  `(call-with-time-limit (lambda () ,@body)))

;;; Scenes ---------------------------------------------------------------------------

(defstruct scene)

(defstruct (table-scene (:include scene))
  (columns '())
  (count 0)
  ;; Of a row's index; answers a list of cells.  Asked a row at a time, and
  ;; only for the rows that are looked at.
  row-function)

(defstruct (text-scene (:include scene))
  (string ""))

(defstruct (stack-scene (:include scene))
  (children '()))

(defstruct (section-scene (:include scene))
  (title "")
  (children '()))

(defstruct (drawing-scene (:include scene))
  (ops '())
  (background nil)
  ;; What to say where a drawing cannot be shown.
  (fallback nil)
  ;; A function of a point on the drawing, x and y in the canvas's units,
  ;; answering what to say about it -- the value under the pointer -- or NIL.
  (readout nil))

(defstruct (native-scene (:include scene))
  ;; A function of no arguments, called on thread 1, answering a view of the
  ;; toolkit's own -- an NSView, a UIView -- autoreleased.
  thunk
  ;; The scene to show where that cannot be: as text, or in a front end that
  ;; has no such toolkit.
  fallback)

(defun inspector:table (&key columns rows count row)
  "A table.  Either ROWS, a list of rows, or COUNT and ROW, a function of a
row's index answering that row -- which is how a vector of a million elements
is a table without being a million rows of anything.

A row is a list of cells.  A cell that is a string is shown as it is: a label.
A cell that is a PLACE is shown as its value, can be walked into, and can be
edited if the place allows.  Any other cell is a value: shown printed, and
walked into."
  (if row
      (make-table-scene :columns columns :count count :row-function row)
      (let ((rows (coerce rows 'vector)))
        (make-table-scene :columns columns :count (length rows)
                          :row-function (lambda (index) (aref rows index))))))

(defun inspector:text (control &rest arguments)
  "Some text.  A format control and its arguments, or just a string."
  (make-text-scene :string (if arguments
                               (apply #'format nil control arguments)
                               (princ-to-string control))))

(defun inspector:stack (&rest scenes)
  "SCENES, one under another."
  (make-stack-scene :children (remove nil scenes)))

(defun inspector:section (title &rest scenes)
  "SCENES under a heading."
  (make-section-scene :title title :children (remove nil scenes)))

(defun inspector:native (thunk &key fallback)
  "A view of the toolkit's own.  THUNK is called on the main thread and answers
an NSView (a UIView, on iOS), autoreleased, which is put in the pane as it is:
an NSImageView for an image, say.  FALLBACK is the scene to show where a native
view cannot be -- printed as text, or on the other platform."
  (make-native-scene :thunk thunk :fallback fallback))

(defun call-with-drawing (function fallback &optional readout)
  ;; The canvas's own machinery, pointed at a list: while *CANVAS-FRAME* is
  ;; bound, LINE and BOX and the rest collect there instead of going to the
  ;; canvas.  The pen and the turtle are bound too, so that a view neither
  ;; inherits the state somebody's doodle left nor leaves its own behind.
  (let ((*canvas-frame* (list '()))
        (*canvas-background* *canvas-default-background*)
        (*canvas-color* '(1d0 1d0 1d0 1d0))
        (*canvas-pen* 1d0)
        (*turtle* (make-turtle-state)))
    (funcall function)
    (make-drawing-scene :ops (reverse (car *canvas-frame*))
                        :background *canvas-background*
                        :fallback fallback
                        :readout readout)))

(defmacro inspector:drawing ((&key fallback readout) &body body)
  "A drawing: whatever BODY draws with the canvas's functions -- LINE, BOX, DOT,
HUE, the turtle -- on a canvas of its own, -100 to 100 each way.  Nothing goes
to the real canvas.  FALLBACK is text to show where a drawing cannot be.

READOUT, if given, is a function of x and y -- a point on the drawing, in the
same units -- answering a string to show while the pointer is there: the value
of the cell under it, the bin it is in.  NIL for a point with nothing to say."
  `(call-with-drawing (lambda () ,@body) ,fallback ,readout))

(defun drawing-readout (scene x y)
  "What SCENE's drawing says about the point (X, Y), or NIL.  Never signals."
  (let ((readout (and (drawing-scene-p scene) (drawing-scene-readout scene))))
    (and readout
         (handler-case (let ((text (funcall readout x y)))
                         (and text (princ-to-string text)))
           (error () nil)))))

;;; Options --------------------------------------------------------------------------

(defstruct view-option
  name                                  ; the symbol the view's lambda list uses
  label
  default
  kind                                  ; :integer :number :boolean :choice
  min max
  choices)

(defun parse-view-option (spec)
  "A VIEW-OPTION from (name default kind &key min max label), or, for a
:CHOICE, (name default :choice (choices...))."
  (destructuring-bind (name default kind &rest rest) spec
    (let ((choices (and (eq kind :choice) (first rest)))
          (keys (if (eq kind :choice) (rest rest) rest)))
      (unless (member kind '(:integer :number :boolean :choice))
        (error "An option is an :integer, a :number, a :boolean or a :choice, not ~s." kind))
      (make-view-option :name name
                        :label (or (getf keys :label)
                                   (substitute #\Space #\- (string-downcase name)))
                        :default default :kind kind
                        :min (getf keys :min) :max (getf keys :max)
                        :choices choices))))

(defun option-keyword (option)
  (intern (symbol-name (view-option-name option)) "KEYWORD"))

(defun coerce-option-value (option value)
  "VALUE as OPTION can take it, or the default where it cannot."
  (flet ((clamp (number)
           (let ((low (view-option-min option)) (high (view-option-max option)))
             (cond ((and low (< number low)) low)
                   ((and high (> number high)) high)
                   (t number)))))
    (ecase (view-option-kind option)
      (:boolean (and value t))
      (:integer (if (realp value) (clamp (round value)) (view-option-default option)))
      (:number (if (realp value) (clamp value) (view-option-default option)))
      (:choice (if (member value (view-option-choices option))
                   value
                   (view-option-default option))))))

;;; Views ----------------------------------------------------------------------------

(defstruct view
  name title type when (priority 0) (options '()) function
  ;; Who contributed it: the package its name is in, and the file.
  package source
  ;; Room for what is not here yet -- :objc-class, :thread, :requires.
  (properties '()))

(defvar *views* '()
  "Every view, in the order they were first defined.")

(defvar *views-lock* (bt:make-lock "lisp-listener views"))

(defun find-view (name)
  (find name *views* :key #'view-name))

(defun register-view (name &rest initargs)
  (let ((view (apply #'make-view :name name
                                 :package (and (symbol-package name)
                                               (package-name (symbol-package name)))
                                 ;; The file's NAME: what is being loaded is
                                 ;; as likely a fasl as the source it came from.
                                 :source (let ((file (or *compile-file-truename* *load-truename*)))
                                           (and file (pathname-name file)))
                                 initargs)))
    (bt:with-lock-held (*views-lock*)
      (let ((old (position name *views* :key #'view-name)))
        (if old
            (setf (nth old *views*) view)
            (setf *views* (append *views* (list view))))))
    name))

(defmacro inspector:define-view ((name &key title (type t) when (priority 0) options
                                  objc-class thread requires properties)
                                 (object &rest lambda-list) &body body)
  "Contribute a view called NAME, for every object of TYPE -- a type specifier --
for which WHEN, a function of the object, if given, is true.

The body is given the object, and the view's OPTIONS by keyword, and answers a
scene: INSPECTOR:TABLE, TEXT, DRAWING, STACK or SECTION.  It draws nothing.

    (inspector:define-view (histogram
                            :title \"Histogram\"
                            :type (vector (unsigned-byte 8))
                            :options ((bins 32 :integer :min 4 :max 256)
                                      (log-scale nil :boolean)))
        (bytes &key bins log-scale)
      (inspector:drawing () ...))

Among the views that apply to an object, a higher PRIORITY comes first, then a
more specific TYPE.  The first two are the ones an inspector opens on.

For Objective-C data, OBJC-CLASS names a class instead of TYPE: the view then
applies to an object of that class or a subclass, wrapped with INSPECTOR:OBJC,
and is given the wrapper -- INSPECTOR:OBJC-POINTER is the pointer.  Such a view
is run on the main thread, where AppKit and UIKit want their objects touched.
REQUIRES is a list of what the front end must be able to show for the view to
apply at all: (:appkit) for a view that answers an NSView."
  (let ((docstring (and (stringp (first body)) (rest body) (first body))))
    `(register-view ',name
                    :title ,(or title (string-capitalize (substitute #\Space #\- (string name))))
                    :type ',(if objc-class 'objc-object type)
                    :when ,(if objc-class
                               `(let ((also ,when))
                                  (lambda (object)
                                    (and (objc-kind-of-p object ,objc-class)
                                         (or (null also) (funcall also object)))))
                               when)
                    :priority ,priority
                    :options (mapcar #'parse-view-option ',options)
                    :properties (list ,@properties
                                      ,@(and objc-class `(:objc-class ,objc-class))
                                      ,@(and thread `(:thread ,thread))
                                      ,@(and requires `(:requires ',requires))
                                      ,@(and docstring `(:documentation ,docstring)))
                    :function (lambda (,object ,@lambda-list)
                                ,@body))))

(defun view-supported-p (view)
  "Whether this front end can show what VIEW needs."
  (subsetp (getf (view-properties view) :requires) (inspector-capabilities)))

(defun view-applicability (view object)
  "Whether VIEW applies to OBJECT, and if it does not, why not, as a second
value: a sentence for the list of every view there is."
  (let ((class (getf (view-properties view) :objc-class))
        (*print-pretty* nil))
    (cond ((not (view-supported-p view))
           (values nil (format nil "Needs ~{~(~a~)~^, ~}, which this is not."
                               (getf (view-properties view) :requires))))
          ((and class (not (objc-object-p object)))
           (values nil (format nil "Needs an Objective-C ~a." class)))
          ((not (ignore-errors (typep object (view-type view))))
           (values nil (format nil "Needs ~(~s~)." (view-type view))))
          ((and (view-when view)
                (not (ignore-errors (funcall (view-when view) object))))
           (values nil (if class
                           (format nil "Needs an Objective-C ~a; this is ~:[something else~;~:*~a~]."
                                   class (objc-class-name-of object))
                           (format nil "Is ~(~s~), but the view's own test says no."
                                   (view-type view)))))
          (t (values t nil)))))

(defun view-applies-p (view object)
  (values (view-applicability view object)))

(defun view-matches (view)
  "What VIEW is matched by, to say in a list of views."
  (let ((class (getf (view-properties view) :objc-class))
        (*print-pretty* nil))
    (cond (class (format nil "Objective-C ~a" class))
          ((view-when view) (format nil "~(~s~), and a test" (view-type view)))
          (t (format nil "~(~s~)" (view-type view))))))

(defun view-more-specific-p (a b)
  "Whether view A's type is strictly inside view B's."
  (and (ignore-errors (subtypep (view-type a) (view-type b)))
       (not (ignore-errors (subtypep (view-type b) (view-type a))))))

(defun applicable-views (object)
  "The views that apply to OBJECT, best first: by priority, then the more
specific type, then the order they were defined in."
  (let ((views (remove-if-not (lambda (view) (view-applies-p view object)) *views*)))
    ;; A stable sort on priority alone, and then specificity settled between
    ;; neighbours of equal priority: SUBTYPEP is a partial order, and SORT
    ;; wants a total one.
    (let ((sorted (stable-sort (copy-list views) #'> :key #'view-priority)))
      (loop with changed = t
            while changed
            do (setf changed nil)
               (loop for cell on sorted
                     for (a b) = cell
                     when (and b
                               (= (view-priority a) (view-priority b))
                               (view-more-specific-p b a))
                       do (rotatef (first cell) (second cell))
                          (setf changed t)))
      sorted)))

(defun view-option-values (view settings)
  "The keyword arguments VIEW is called with: each option's value from
SETTINGS, a plist by keyword, or its default."
  (loop for option in (view-options view)
        for keyword = (option-keyword option)
        append (list keyword
                     (coerce-option-value
                      option
                      (getf settings keyword (view-option-default option))))))

(defun view-scene (view object &optional settings)
  "The scene VIEW answers for OBJECT.  Whatever it signals comes back as a
scene that says so: a view is somebody else's code, run on a value it may not
have expected, and the inspector's window is not where to find that out."
  (handler-case
      (let ((scene (with-time-limit ()
                     (apply (view-function view) object
                            (view-option-values view settings)))))
        (if (scene-p scene)
            scene
            (inspector:text "The view ~a answered ~s, which is not a scene."
                            (view-title view) scene)))
    (error (condition)
      (inspector:text "The view ~a could not show this:~%~a"
                      (view-title view) (report-condition condition)))))

;;; Controls -------------------------------------------------------------------------

(defstruct control
  kind                                  ; :slider :field :toggle :button
  label
  place                                 ; for all but a button
  min max
  action)                               ; a button's function, of no arguments

(defun inspector:slider (label place &key (min 0) (max 1))
  "A slider that sets PLACE, a real number from MIN to MAX."
  (make-control :kind :slider :label label :place place :min min :max max))

(defun inspector:field (label place)
  "A field: what is typed in it is read, evaluated, and put at PLACE."
  (make-control :kind :field :label label :place place))

(defun inspector:toggle (label place)
  "A checkbox that sets PLACE to true or false."
  (make-control :kind :toggle :label label :place place))

(defun inspector:button (label action)
  "A button that calls ACTION, a function of no arguments."
  (make-control :kind :button :label label :action action))

(defstruct contributor
  name title type when function package)

(defvar *contributors* '()
  "Every DEFINE-CONTROLS, in the order they were first defined.")

(defun register-controls (name &rest initargs)
  (let ((contributor (apply #'make-contributor
                            :name name
                            :package (and (symbol-package name)
                                          (package-name (symbol-package name)))
                            initargs)))
    (bt:with-lock-held (*views-lock*)
      (let ((old (position name *contributors* :key #'contributor-name)))
        (if old
            (setf (nth old *contributors*) contributor)
            (setf *contributors* (append *contributors* (list contributor))))))
    name))

(defmacro inspector:define-controls ((name &key title (type t) when objc-class) (object)
                                     &body body)
  "Contribute controls, called NAME, for every object of TYPE for which WHEN,
if given, is true.  The body answers a list of them -- INSPECTOR:SLIDER, FIELD,
TOGGLE, BUTTON -- each bound to a place:

    (inspector:define-controls (plate-controls :type plate) (plate)
      (list (inspector:slider \"Ambient\" (inspector:slot-place plate 'ambient)
                              :min 0 :max 100)))

A control changes the object, through its place, and every open view of the
object is drawn again."
  `(register-controls ',name
                      :title ,(or title (string-capitalize (substitute #\Space #\- (string name))))
                      :type ',(if objc-class 'objc-object type)
                      :when ,(if objc-class
                                 `(let ((also ,when))
                                    (lambda (object)
                                      (and (objc-kind-of-p object ,objc-class)
                                           (or (null also) (funcall also object)))))
                                 when)
                      :function (lambda (,object) ,@body)))

(defun applicable-controls (object)
  "The controls contributed for OBJECT, as a list of (TITLE . CONTROLS), one
per contributor that had any.  A contributor that signals is left out and
said so in the log."
  (loop for contributor in *contributors*
        when (and (ignore-errors (typep object (contributor-type contributor)))
                  (or (null (contributor-when contributor))
                      (ignore-errors (funcall (contributor-when contributor) object))))
          append (handler-case
                     (let ((controls (remove-if-not #'control-p
                                                    (funcall (contributor-function contributor)
                                                             object))))
                       (and controls
                            (list (cons (contributor-title contributor) controls))))
                   (error (condition)
                     (note "inspector: the controls ~a: ~a"
                           (contributor-name contributor) condition)
                     nil))))
