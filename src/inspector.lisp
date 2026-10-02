;;;; src/inspector.lisp -- an inspector: the session, the thread it thinks on,
;;;; and what it hands a front end.
;;;;
;;;; (inspect x) at the prompt opens one.  It has an object, the PATH walked to
;;;; it from where it started, and two PANES, each showing one of the views
;;;; that apply (src/views.lisp) -- a byte vector's histogram beside its hex.
;;;;
;;;; THE SPLIT IS THE LISTENER'S OWN, with one thread more.  A view is somebody's
;;;; code: it reads slots, calls PRINT-OBJECT, and may take a while or signal.
;;;; Thread 1 never evaluates, so none of that may happen there; and the
;;;; listener thread is busy being a listener.  So an inspector thinks on a
;;;; WORKER thread: every scene is computed there, every place read and written
;;;; there, and what comes out is a MODEL -- strings, numbers and lists of
;;;; shapes, nothing left to evaluate -- which hops to thread 1 for the window
;;;; to show.  What the window is asked to do (choose a view, open a row, set a
;;;; value) goes the other way as a job.
;;;;
;;;; With no main thread to hop to -- `make test' -- a job is simply run where
;;;; it was asked for, and the model is there when the call returns.  And with
;;;; a front end that has no inspector window -- iOS, for now -- (inspect x)
;;;; PRINTS the model, which is the same data read another way.
;;;;
;;;; The front end supplies three functions, declaimed in impl.lisp:
;;;; INSPECTOR-CAPABILITIES, SHOW-INSPECTOR and REFRESH-INSPECTOR.

(in-package #:lisp-listener)

;;; Printing, within reason ------------------------------------------------------------

(defparameter *inspector-print-length* 12)
(defparameter *inspector-print-level* 3)
(defparameter *inspector-cell-width* 240
  "The most of a value's printed form a cell keeps.")
(defparameter *inspector-row-chunk* 200
  "How many rows of a table are computed at a time.")

(defun clip-string (string limit)
  (let ((line (substitute #\Space #\Newline string)))
    (if (> (length line) limit)
        (concatenate 'string (subseq line 0 (1- limit)) "…")
        line)))

(defun inspector-print (object &optional (limit *inspector-cell-width*))
  "OBJECT printed for a cell: on one line, bounded, and never signalling."
  (let ((*print-length* *inspector-print-length*)
        (*print-level* *inspector-print-level*)
        (*print-circle* t)
        (*print-pretty* nil)
        (*print-readably* nil))
    (clip-string (handler-case (prin1-to-string object)
                   (error (condition)
                     (format nil "#<unprintable ~a: ~a>"
                             (ignore-errors (type-of object))
                             (report-condition condition))))
                 limit)))

;;; The model: what a front end is given ---------------------------------------------

(defstruct row
  (header-p nil)
  (cells '())                           ; strings
  (places '())                          ; a place or NIL, per cell
  ;; Whether the row's place may be set: asked on the worker, with the rest,
  ;; so that thread 1 need call nobody's method to know.
  (editable nil))

(defstruct table-model
  (columns '())
  (count 0)
  ;; (:header TITLE) and (:rows COUNT FUNCTION) in order, which is how several
  ;; tables and their headings are one table to scroll.
  (segments '())
  ;; Row index -> ROW, for the rows computed so far.
  (rows (make-hash-table)))

(defstruct option-model
  keyword label kind value min max choices)

(defstruct pane-model
  view-name view-title
  (choices '())                         ; (NAME . TITLE), every applicable view
  (options '())
  drawing                               ; a DRAWING-SCENE, or NIL
  table                                 ; a TABLE-MODEL, or NIL
  (text ""))

(defstruct control-model
  group label kind value min max enabled
  control)                              ; the CONTROL itself, for the worker

(defstruct model
  (path '())                            ; the labels, root first
  (title "")
  (panes '())
  (about '())                           ; (LABEL . STRING)
  (controls '())
  (views '())                           ; (TITLE . CONTRIBUTOR)
  (message nil))

;;; The session ----------------------------------------------------------------------

(defstruct object-state
  (views (list nil nil))                ; the view chosen in each pane, by name
  (settings '()))                       ; (VIEW-NAME . plist of option values)

(defvar *inspector-count* 0)

(defstruct (inspector (:constructor %make-inspector))
  (id (incf *inspector-count*))
  (path '())                            ; (LABEL . OBJECT), root first
  (states (make-hash-table :test 'eql))
  (model nil)                           ; thread 1's, once delivered
  (package nil)
  (listener nil)
  (message nil)
  (update-queued nil)
  ;; The front end's: its window and what is in it.
  (retained '()))

(defvar *inspectors* '()
  "Every inspector with a window, newest first.")

(defvar *inspectors-lock* (bt:make-lock "lisp-listener inspectors"))

(defun make-inspector (object &optional (listener *listener*))
  (%make-inspector :path (list (cons (inspector-print object 40) object))
                   :package (or (and listener (listener-package listener))
                                *package*)
                   :listener listener))

(defun inspector-object (inspector)
  "The object INSPECTOR is looking at now: the end of its path."
  (cdr (first (last (inspector-path inspector)))))

(defun inspector-state (inspector object)
  (or (gethash object (inspector-states inspector))
      (setf (gethash object (inspector-states inspector)) (make-object-state))))

;;; From a scene to a pane -------------------------------------------------------------

(defun flatten-scene (scene)
  "SCENE as the three things a pane can show: the first drawing in it, its
tables and headings as the segments of one table, and its text."
  (let ((drawing nil) (segments '()) (columns nil) (texts '()))
    (labels ((walk (scene)
               (etypecase scene
                 (drawing-scene (unless drawing (setf drawing scene)))
                 (text-scene (push (text-scene-string scene) texts))
                 (table-scene
                  (unless columns (setf columns (table-scene-columns scene)))
                  (push (list :rows (table-scene-count scene)
                              (table-scene-row-function scene))
                        segments))
                 (stack-scene (mapc #'walk (stack-scene-children scene)))
                 (section-scene
                  (if (some #'table-scene-p (section-scene-children scene))
                      (push (list :header (section-scene-title scene)) segments)
                      (push (format nil "~a" (section-scene-title scene)) texts))
                  (mapc #'walk (section-scene-children scene))))))
      (walk scene))
    (values drawing (nreverse segments) columns
            (format nil "~{~a~^~%~%~}" (nreverse texts)))))

(defun table-from-segments (segments columns)
  (and segments
       (make-table-model
        :columns columns
        :segments segments
        :count (loop for segment in segments
                     sum (if (eq (first segment) :header) 1 (second segment))))))

(defun compute-row (table index)
  "Row INDEX of TABLE, computed: its cells printed, its places kept."
  (let ((at 0))
    (dolist (segment (table-model-segments table)
                     (make-row :cells (list "")))
      (ecase (first segment)
        (:header
         (when (= index at)
           (return (make-row :header-p t :cells (list (second segment)))))
         (incf at))
        (:rows
         (destructuring-bind (count function) (rest segment)
           (when (< index (+ at count))
             (return
               (handler-case
                   (let ((cells '()) (places '()))
                     (dolist (cell (funcall function (- index at)))
                       (cond ((stringp cell)
                              (push cell cells) (push nil places))
                             (t
                              (let ((place (if (typep cell 'inspector:place)
                                               cell
                                               (inspector:value cell))))
                                (push (if (inspector:place-bound-p place)
                                          (inspector-print (inspector:place-value place))
                                          "#<unbound>")
                                      cells)
                                (push place places)))))
                     (let ((row (make-row :cells (nreverse cells)
                                          :places (nreverse places))))
                       (setf (row-editable row)
                             (let ((place (row-place row)))
                               (and place (inspector:place-supports-p place :set) t)))
                       row))
                 (error (condition)
                   (make-row :cells (list "" (format nil "#<error: ~a>"
                                                     (report-condition condition))))))))
           (incf at count)))))))

(defun ensure-rows (table upto)
  "Compute TABLE's rows up to index UPTO, those not computed already."
  (let ((rows (table-model-rows table)))
    (loop for index from 0 below (min (1+ upto) (table-model-count table))
          unless (gethash index rows)
            do (setf (gethash index rows) (compute-row table index))))
  table)

(defun table-row (table index)
  "Row INDEX of TABLE if it has been computed, else NIL.  Any thread: the rows
already there are only ever added to."
  (and table (gethash index (table-model-rows table))))

(defun pane-for-view (view object settings choices)
  (multiple-value-bind (drawing segments columns text)
      (flatten-scene (view-scene view object settings))
    (let ((table (table-from-segments segments columns)))
      (when table
        (ensure-rows table (1- *inspector-row-chunk*)))
      (make-pane-model
       :view-name (view-name view)
       :view-title (view-title view)
       :choices choices
       :options (loop with values = (view-option-values view settings)
                      for option in (view-options view)
                      for keyword = (option-keyword option)
                      collect (make-option-model
                               :keyword keyword
                               :label (view-option-label option)
                               :kind (view-option-kind option)
                               :value (getf values keyword)
                               :min (view-option-min option)
                               :max (view-option-max option)
                               :choices (view-option-choices option)))
       :drawing drawing
       :table table
       :text text))))

(defun describe-size (object)
  (typecase object
    (string (format nil "~d character~:p" (length object)))
    (vector (format nil "~d element~:p" (length object)))
    (array (format nil "~{~d~^ × ~}" (array-dimensions object)))
    (hash-table (format nil "~d entr~:@p" (hash-table-count object)))
    (list (let ((length (ignore-errors (list-length object))))
            (if length (format nil "~d element~:p" length) "circular")))
    (t nil)))

(defun compute-model (inspector)
  "Everything a front end shows of INSPECTOR, computed now.  The worker's."
  (let* ((*package* (or (inspector-package inspector) *package*))
         (object (inspector-object inspector))
         (state (inspector-state inspector object))
         (views (applicable-views object))
         (choices (mapcar (lambda (view) (cons (view-name view) (view-title view))) views))
         (message (shiftf (inspector-message inspector) nil)))
    ;; The view in each pane: the one chosen, while it still applies; else the
    ;; best two, in order.
    (loop for pane from 0 below 2
          for chosen = (nth pane (object-state-views state))
          unless (and chosen (find chosen views :key #'view-name))
            do (setf (nth pane (object-state-views state))
                     (let ((view (or (nth pane views) (first views))))
                       (and view (view-name view)))))
    (make-model
     :path (mapcar #'car (inspector-path inspector))
     :title (inspector-print object 60)
     :panes (loop for name in (object-state-views state)
                  for view = (find name views :key #'view-name)
                  collect (and view
                               (pane-for-view view object
                                              (cdr (assoc name (object-state-settings state)))
                                              choices)))
     :about (remove nil
                    (list (cons "Type" (inspector-print (ignore-errors (type-of object)) 80))
                          (cons "Class" (inspector-print
                                         (ignore-errors (class-name (class-of object))) 80))
                          (let ((size (ignore-errors (describe-size object))))
                            (and size (cons "Size" size)))))
     :controls (loop for (group . controls) in (applicable-controls object)
                     append (loop for control in controls
                                  for place = (control-place control)
                                  collect (make-control-model
                                           :group group
                                           :label (control-label control)
                                           :kind (control-kind control)
                                           :value (and place
                                                       (ignore-errors
                                                        (inspector:place-value place)))
                                           :min (control-min control)
                                           :max (control-max control)
                                           :enabled (or (null place)
                                                        (and (inspector:place-supports-p
                                                              place :set)
                                                             t))
                                           :control control)))
     :views (mapcar (lambda (view)
                      (cons (view-title view)
                            (format nil "~(~a~)~@[ · ~a~]"
                                    (or (view-package view) "?") (view-source view))))
                    views)
     :message message)))

;;; The worker -----------------------------------------------------------------------

(defvar *inspector-jobs* '()
  "Closures for the worker, newest first.")

(defvar *inspector-jobs-lock* (bt:make-lock "lisp-listener inspector jobs"))
(defvar *inspector-jobs-ready* (bt:make-condition-variable :name "lisp-listener inspector jobs"))
(defvar *inspector-worker* nil)

(defun inspector-worker-loop ()
  (loop
    (let ((job (bt:with-lock-held (*inspector-jobs-lock*)
                 (loop while (null *inspector-jobs*)
                       do (bt:condition-wait *inspector-jobs-ready* *inspector-jobs-lock*))
                 (let ((oldest (first (last *inspector-jobs*))))
                   (setf *inspector-jobs* (butlast *inspector-jobs*))
                   oldest))))
      (handler-case (funcall job)
        (error (condition)
          (note "inspector: ~a" condition))))))

(defun run-on-worker (function)
  "Call FUNCTION on the inspector's thread -- or here and now, when there is no
main thread to hand the result to, which is what makes `make test' able to ask
and then look."
  (cond ((null *main-thread-target*) (funcall function))
        (t
         (bt:with-lock-held (*inspector-jobs-lock*)
           (unless (and *inspector-worker* (bt:thread-alive-p *inspector-worker*))
             (setf *inspector-worker*
                   (bt:make-thread #'inspector-worker-loop :name "lisp listener inspector")))
           (push function *inspector-jobs*)
           (bt:condition-notify *inspector-jobs-ready*))))
  (values))

(defun deliver-model (inspector model)
  (cond (*main-thread-target*
         (on-main-thread ()
           (setf (inspector-model inspector) model)
           (refresh-inspector inspector)))
        (t (setf (inspector-model inspector) model))))

(defun inspector-update (inspector &optional action)
  "Do ACTION, if any, on the worker; then compute INSPECTOR's model again and
hand it over.  An ACTION that signals leaves its report as the model's
message, where the window shows it.

Asked for many times before the worker gets to it -- a simulation calling
NOTE-CHANGED every step -- it is computed once."
  (flet ((update ()
           (setf (inspector-update-queued inspector) nil)
           (when action
             (handler-case (let ((*package* (or (inspector-package inspector) *package*)))
                             (funcall action))
               (error (condition)
                 (setf (inspector-message inspector) (report-condition condition)))))
           (deliver-model inspector (compute-model inspector))))
    (cond (action (run-on-worker #'update))
          ((inspector-update-queued inspector) nil)
          (t (setf (inspector-update-queued inspector) t)
             (run-on-worker #'update))))
  inspector)

;;; What a front end asks for -------------------------------------------------------
;;;
;;; Each of these is called on thread 1 and returns at once; the answer is a
;;; new model, later.

(defun inspector-refresh (inspector)
  (inspector-update inspector))

(defun inspector-select-view (inspector pane view-name)
  "Show the view called VIEW-NAME in pane number PANE."
  (inspector-update
   inspector
   (lambda ()
     (setf (nth pane (object-state-views
                      (inspector-state inspector (inspector-object inspector))))
           view-name))))

(defun inspector-set-option (inspector pane keyword value)
  "Set the option KEYWORD of the view in PANE to VALUE."
  (inspector-update
   inspector
   (lambda ()
     (let* ((state (inspector-state inspector (inspector-object inspector)))
            (name (nth pane (object-state-views state)))
            (entry (or (assoc name (object-state-settings state))
                       (first (push (cons name '()) (object-state-settings state))))))
       (setf (getf (cdr entry) keyword) value)))))

(defun inspector-pane-row (inspector pane index)
  (let* ((model (inspector-model inspector))
         (pane-model (and model (nth pane (model-panes model)))))
    (and pane-model (table-row (pane-model-table pane-model) index))))

(defun row-place (row)
  "The place a row is about: its last, which is its value in the usual row of
a name and a value."
  (and row (find-if-not #'null (row-places row) :from-end t)))

(defun inspector-open-row (inspector pane index)
  "Walk into row INDEX of PANE: the inspector now looks at that row's value."
  (let* ((row (inspector-pane-row inspector pane index))
         (place (row-place row)))
    (when place
      (inspector-update
       inspector
       (lambda ()
         (let ((value (inspector:place-value place)))
           (setf (inspector-path inspector)
                 (append (inspector-path inspector)
                         (list (cons (or (inspector:place-label place)
                                         (let ((label (first (row-cells row))))
                                           (and (stringp label) (plusp (length label)) label))
                                         (inspector-print value 30))
                                     value))))))))))

(defun inspector-open-object (inspector object &optional label)
  "Walk into OBJECT, from wherever INSPECTOR is."
  (inspector-update
   inspector
   (lambda ()
     (setf (inspector-path inspector)
           (append (inspector-path inspector)
                   (list (cons (or label (inspector-print object 30)) object)))))))

(defun inspector-go-to (inspector depth)
  "Go back to step DEPTH of the path, 0 being where the inspector started."
  (inspector-update
   inspector
   (lambda ()
     (setf (inspector-path inspector)
           (subseq (inspector-path inspector)
                   0 (max 1 (min (1+ depth) (length (inspector-path inspector)))))))))

(defun set-place-from-text (place text)
  "Read TEXT, evaluate it, and put the value at PLACE -- if it may be put there."
  (unless (inspector:place-supports-p place :set)
    (error "This cannot be changed."))
  (let ((value (eval (let ((*read-eval* t)) (read-from-string text)))))
    (unless (inspector:place-accepts-p place value)
      (error "~a is not something this can hold." (inspector-print value 60)))
    (setf (inspector:place-value place) value)))

(defun inspector-edit-row (inspector pane index text)
  "Put the value of TEXT -- a form, read and evaluated -- at row INDEX of PANE."
  (let ((place (row-place (inspector-pane-row inspector pane index))))
    (when place
      (inspector-update
       inspector
       (lambda ()
         (set-place-from-text place text)
         (note-changed-elsewhere inspector))))))

(defun inspector-set-control (inspector index &optional value)
  "Work the control at INDEX in the model: set its place to VALUE, or press it."
  (let* ((model (inspector-model inspector))
         (control-model (and model (nth index (model-controls model))))
         (control (and control-model (control-model-control control-model))))
    (when control
      (inspector-update
       inspector
       (lambda ()
         (let ((place (control-place control)))
           (ecase (control-kind control)
             (:button (funcall (control-action control)))
             (:toggle (setf (inspector:place-value place) (and value t)))
             (:field (set-place-from-text place value))
             (:slider
              ;; A slider deals in floats.  A place that will not take one but
              ;; will take the nearest integer wanted an integer.
              (let ((number (cond ((inspector:place-accepts-p place value) value)
                                  ((inspector:place-accepts-p place (round value))
                                   (round value))
                                  (t (error "~a is not something this can hold."
                                            (inspector-print value 60))))))
                (setf (inspector:place-value place) number)))))
         (note-changed-elsewhere inspector))))))

(defun inspector-need-rows (inspector pane upto)
  "Compute the rows of PANE's table up to UPTO, and say when they are there."
  (let* ((model (inspector-model inspector))
         (pane-model (and model (nth pane (model-panes model))))
         (table (and pane-model (pane-model-table pane-model))))
    (when table
      (run-on-worker
       (lambda ()
         (let ((*package* (or (inspector-package inspector) *package*)))
           (ensure-rows table (+ upto *inspector-row-chunk*)))
         (deliver-model inspector model))))))

;;; Changed --------------------------------------------------------------------------

(defun inspectors-showing (object)
  (bt:with-lock-held (*inspectors-lock*)
    (remove-if-not (lambda (inspector)
                     (find object (inspector-path inspector) :key #'cdr))
                   *inspectors*)))

(defun note-changed-elsewhere (inspector)
  "INSPECTOR changed what it looks at: the others looking at it should look again."
  (dolist (object (mapcar #'cdr (inspector-path inspector)))
    (dolist (other (inspectors-showing object))
      (unless (eq other inspector)
        (inspector-update other)))))

(defun inspector:note-changed (&optional (object nil object-p))
  "Say that OBJECT has changed, so that every inspector showing it shows it as
it is now.  With no argument, every inspector looks again.

What a program calls when it changes something behind an inspector's back; a
change made THROUGH an inspector says so itself."
  (dolist (inspector (if object-p
                         (inspectors-showing object)
                         (bt:with-lock-held (*inspectors-lock*) (copy-list *inspectors*))))
    (inspector-update inspector))
  (values))

;;; As text --------------------------------------------------------------------------

(defparameter *inspector-text-rows* 24
  "How many rows of a table the text form shows.")

(defun print-pane (pane stream)
  "PANE as text: its drawing's fallback, its text, and the head of its table."
  (let ((drawing (pane-model-drawing pane))
        (table (pane-model-table pane))
        (text (pane-model-text pane)))
    (when drawing
      (format stream "~a~%"
              (or (drawing-scene-fallback drawing)
                  (format nil "[a drawing of ~d shape~:p]"
                          (length (drawing-scene-ops drawing))))))
    (when (plusp (length text))
      (format stream "~a~%" text))
    (when table
      (let* ((shown (min (table-model-count table) *inspector-text-rows*))
             (rows (progn (ensure-rows table (1- shown))
                          (loop for index below shown collect (table-row table index))))
             (width (min 28 (or (loop for row in rows
                                      unless (row-header-p row)
                                        maximize (length (first (row-cells row))))
                                0))))
        (dolist (row rows)
          (if (row-header-p row)
              (format stream "~a~%" (first (row-cells row)))
              (format stream "  ~va~{  ~a~}~%" width
                      (first (row-cells row)) (rest (row-cells row)))))
        (when (> (table-model-count table) shown)
          (format stream "  … and ~d more~%" (- (table-model-count table) shown)))))))

(defun print-inspector (inspector &optional (stream *standard-output*))
  "INSPECTOR as text: what it is looking at, in its first pane's view, and the
other views there are."
  (let* ((model (or (inspector-model inspector)
                    (setf (inspector-model inspector) (compute-model inspector))))
         (pane (first (model-panes model))))
    (format stream "~&~a~%" (model-title model))
    (loop for (label . value) in (model-about model)
          do (format stream "  ~a: ~a~%" label value))
    (when pane
      (format stream "~%~a~%" (pane-model-view-title pane))
      (print-pane pane stream)
      (let ((others (remove (pane-model-view-title pane)
                            (mapcar #'cdr (pane-model-choices pane)) :test #'string=)))
        (when others
          (format stream "~%Other views: ~{~a~^, ~}.~%" others)))))
  (values))

(defun inspector:views (object)
  "The titles of the views that apply to OBJECT, best first."
  (mapcar #'view-title (applicable-views object)))

(defun inspector:show (object &optional view-title &rest options)
  "Print OBJECT as the view called VIEW-TITLE shows it -- or its best view --
with OPTIONS, the view's own, by keyword.  The inspector, without a window:

    (inspector:show (make-array 4 :element-type '(unsigned-byte 8)) \"Hex\")"
  (let* ((views (applicable-views object))
         (view (if view-title
                   (or (find view-title views :key #'view-title :test #'string-equal)
                       (error "No view called ~a applies to this.  These do: ~{~a~^, ~}."
                              view-title (mapcar #'view-title views)))
                   (first views))))
    (format t "~&")
    (print-pane (pane-for-view view object options '()) *standard-output*)
    (values)))

;;; INSPECT --------------------------------------------------------------------------

(defun inspect-object (object &optional (listener *listener*))
  "Open an inspector on OBJECT: in a window where the front end has one, and
as text in the transcript where it has not.  Answers no values, so that what
was inspected is not printed again under it."
  (let ((inspector (make-inspector object listener)))
    (cond ((and *main-thread-target* (inspector-capabilities))
           (bt:with-lock-held (*inspectors-lock*)
             (push inspector *inspectors*))
           (run-on-worker
            (lambda ()
              (let ((model (compute-model inspector)))
                (on-main-thread ()
                  (setf (inspector-model inspector) model)
                  (show-inspector inspector))))))
          (t (print-inspector inspector *standard-output*))))
  (values))

(defun inspector-closed (inspector)
  "INSPECTOR's window has gone.  Thread 1."
  (bt:with-lock-held (*inspectors-lock*)
    (setf *inspectors* (remove inspector *inspectors*)))
  inspector)
