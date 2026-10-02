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
  ;; Per cell, whether its place may be set, and whether it may be removed:
  ;; asked on the worker, with the rest, so that thread 1 need call nobody's
  ;; method to know.
  (editable '())
  (removable '())
  (insertable '()))

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
  (text "")
  ;; A function answering a view of the toolkit's own, to be called on thread
  ;; 1, or NIL: a NATIVE scene's.  And what that scene falls back to, as
  ;; text, for when the pane is printed rather than shown.
  native
  (native-text ""))

(defstruct control-model
  group label kind value min max enabled
  control)                              ; the CONTROL itself, for the worker

(defstruct model
  (path '())                            ; the labels, root first
  ;; The objects those labels stand for, root first: what says WHERE the
  ;; inspector is.  The labels cannot -- they are printed afresh each time,
  ;; and change when the object does.
  (steps '())
  (title "")
  (panes '())
  (about '())                           ; (LABEL . STRING)
  (controls '())
  (views '())                           ; (TITLE . CONTRIBUTOR)
  ;; What can be added to the object: NIL, :VALUE or :KEY-AND-VALUE.
  (addition nil)
  ;; Every view there is, applicable or not, each a plist: :NAME :TITLE
  ;; :MATCHES :CONTRIBUTOR :PRIORITY :APPLIES and, where it does not, :REASON.
  (all-views '())
  ;; What a view of the caller's own would say to match this object, as it
  ;; would be typed: ":type vector", or ":objc-class \"NSWindow\"".
  (match "")
  (message nil))

;;; The session ----------------------------------------------------------------------

(defstruct object-state
  (views (list nil nil))                ; the view chosen in each pane, by name
  (settings '()))                       ; (VIEW-NAME . plist of option values)

(defvar *inspector-count* 0)

(defstruct (inspector (:constructor %make-inspector))
  (id (incf *inspector-count*))
  ;; (LABEL . OBJECT), root first.  A LABEL of NIL means "however the object
  ;; prints now": the root's, which would otherwise go on saying (:A :B) after
  ;; the list had become (:A :C).
  (path '())
  (states (make-hash-table :test 'eql))
  (model nil)                           ; thread 1's, once delivered
  (package nil)
  (listener nil)
  (message nil)
  (update-queued nil)
  ;; The point last asked about on a drawing, (PANE X Y), until the worker
  ;; gets to it; and what it said, where there is no window to say it in.
  (readout-request nil)
  (readout nil)
  ;; Objective-C objects walked into, retained for as long as this is open: a
  ;; pointer in a Lisp list keeps nothing alive.
  (retained-objects '())
  ;; The front end's: its window and what is in it.
  (retained '()))

(defvar *inspectors* '()
  "Every inspector with a window, newest first.")

(defvar *inspectors-lock* (bt:make-lock "lisp-listener inspectors"))

(defun make-inspector (object &optional (listener *listener*))
  (let ((inspector (%make-inspector
                    :path (list (cons nil object))
                    :package (or (and listener (listener-package listener))
                                 *package*)
                    :listener listener)))
    (hold-objc-object inspector object)
    inspector))

(defun hold-objc-object (inspector object)
  "Retain OBJECT for INSPECTOR, if it is an Objective-C object."
  (when (and (objc-object-p object)
             (not (member object (inspector-retained-objects inspector))))
    (ignore-errors (objc:retain (objc-object-pointer object)))
    (push object (inspector-retained-objects inspector)))
  object)

(defun walk-into (inspector object label)
  "Put OBJECT on the end of INSPECTOR's path."
  (hold-objc-object inspector object)
  (setf (inspector-path inspector)
        (append (inspector-path inspector) (list (cons label object)))))

(defun inspector-object (inspector)
  "The object INSPECTOR is looking at now: the end of its path."
  (cdr (first (last (inspector-path inspector)))))

(defun inspector-state (inspector object)
  (or (gethash object (inspector-states inspector))
      (setf (gethash object (inspector-states inspector)) (make-object-state))))

;;; From a scene to a pane -------------------------------------------------------------

(defun flatten-scene (scene)
  "SCENE as the things a pane can show: the first drawing in it, its tables
and headings as the segments of one table, its text, and -- where the front
end can show one -- its native view's function."
  (let ((drawing nil) (segments '()) (columns nil) (texts '()) (native nil)
        (native-text ""))
    (labels ((walk (scene)
               (etypecase scene
                 (native-scene
                  ;; A view of the toolkit's own where there is that toolkit
                  ;; to show it, and what it falls back to where there is not.
                  (cond ((and (member :native (inspector-capabilities)) (not native))
                         (setf native (native-scene-thunk scene))
                         (when (native-scene-fallback scene)
                           (setf native-text
                                 (nth-value 3 (flatten-scene
                                               (inspector:stack
                                                (native-scene-fallback scene)))))))
                        ((native-scene-fallback scene)
                         (walk (native-scene-fallback scene)))))
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
            (format nil "~{~a~^~%~%~}" (nreverse texts))
            native native-text)))

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
                     (let ((places (nreverse places)))
                       (flet ((supports (operation)
                                (mapcar (lambda (place)
                                          (and place
                                               (inspector:place-supports-p place operation)
                                               t))
                                        places)))
                         (make-row :cells (nreverse cells) :places places
                                   :editable (supports :set)
                                   :removable (supports :remove)
                                   :insertable (supports :insert)))))
                 (error (condition)
                   (make-row :cells (list "" (format nil "#<error: ~a>"
                                                     (report-condition condition))))))))
           (incf at count)))))))

(defun ensure-rows (table upto)
  "Compute TABLE's rows up to index UPTO, those not computed already."
  (let ((rows (table-model-rows table)))
    (loop for index from 0 below (min (1+ upto) (table-model-count table))
          unless (gethash index rows)
            do (setf (gethash index rows)
                     (handler-case (with-time-limit () (compute-row table index))
                       (inspector-timeout ()
                         (make-row :cells (list "" "#<took too long>")))))))
  table)

(defun table-row (table index)
  "Row INDEX of TABLE if it has been computed, else NIL.  Any thread: the rows
already there are only ever added to."
  (and table (gethash index (table-model-rows table))))

(defun pane-for-view (view object settings choices)
  (multiple-value-bind (drawing segments columns text native native-text)
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
       :text text
       :native native
       :native-text native-text))))

(defun describe-size (object)
  (typecase object
    (string (format nil "~d character~:p" (length object)))
    (vector (format nil "~d element~:p" (length object)))
    (array (format nil "~{~d~^ × ~}" (array-dimensions object)))
    (hash-table (format nil "~d entr~:@p" (hash-table-count object)))
    (list (let ((length (ignore-errors (list-length object))))
            (if length (format nil "~d element~:p" length) "circular")))
    (t nil)))

(defun object-match (object)
  "What a DEFINE-VIEW would say to match OBJECT, as text: the most specific of
its classes that has a name anyone would type -- one that prints without a
double colon -- or its Objective-C class."
  (if (objc-object-p object)
      (format nil ":objc-class ~s" (or (objc-class-name-of object) "NSObject"))
      (format nil ":type ~(~a~)"
              (or (find-if (lambda (name)
                             (and name (symbolp name)
                                  (not (search "::" (prin1-to-string name)))))
                           (class-precedence-names (class-of object)))
                  t))))

(defun describe-object-kind (object)
  "The Type and Class lines of the object panel, as (LABEL . STRING)s."
  (if (objc-object-p object)
      ;; The wrapper is nobody's business: what it wraps is.
      (list (cons "Type" "an Objective-C object")
            (cons "Class" (or (objc-class-name-of object) "?")))
      (list (cons "Type" (inspector-print (ignore-errors (type-of object)) 80))
            (cons "Class" (inspector-print
                           (ignore-errors (class-name (class-of object))) 80)))))

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
     :path (loop for (label . step) in (inspector-path inspector)
                 for root = t then nil
                 collect (or label (inspector-print step (if root 40 30))))
     :steps (mapcar #'cdr (inspector-path inspector))
     :title (inspector-print object 60)
     :panes (loop for name in (object-state-views state)
                  for view = (find name views :key #'view-name)
                  collect (and view
                               (pane-for-view view object
                                              (cdr (assoc name (object-state-settings state)))
                                              choices)))
     :about (remove nil
                    (append (describe-object-kind object)
                            (list (let ((size (ignore-errors (describe-size object))))
                                    (and size (cons "Size" size))))))
     :match (or (ignore-errors (object-match object)) ":type t")
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
     :addition (ignore-errors (inspector:addition object))
     :all-views (mapcar (lambda (view)
                          (multiple-value-bind (applies reason)
                              (view-applicability view object)
                            (list :name (view-name view)
                                  :title (view-title view)
                                  :matches (view-matches view)
                                  :contributor (format nil "~(~a~)~@[ · ~a~]"
                                                       (or (view-package view) "?")
                                                       (view-source view))
                                  :priority (view-priority view)
                                  :documentation (getf (view-properties view)
                                                       :documentation)
                                  :applies applies
                                  :reason reason)))
                        *views*)
     :views (mapcar (lambda (view)
                      (cons (view-title view)
                            (format nil "~(~a~)~@[ · ~a~]"
                                    (or (view-package view) "?") (view-source view))))
                    views)
     :message message)))

(defun same-steps-p (a b)
  "Whether two models' STEPS are the same walk: the same objects, in order."
  (and (= (length a) (length b)) (every #'eq a b)))

(defun model-views-sorted (model)
  "Every view there is, those that apply to the model's object first; each
the model's plist.  For a front end's list of them."
  (stable-sort (copy-list (model-all-views model))
               (lambda (a b) (and (getf a :applies) (not (getf b :applies))))))

;;; The worker -----------------------------------------------------------------------

(defvar *inspector-jobs* '()
  "Closures for the worker, newest first.")

(defvar *inspector-jobs-lock* (bt:make-lock "lisp-listener inspector jobs"))
(defvar *inspector-jobs-ready* (bt:make-condition-variable :name "lisp-listener inspector jobs"))

(defvar *inspector-worker-mode* :auto
  "When the worker is used: :AUTO means whenever there is a main thread to
hand a result to, which is always but under `make test'.  T means always, for
the test of the worker itself.")

(defvar *inspector-watchdog* nil)

(defun inspector-watchdog-loop ()
  ;; For as long as there is a worker to watch.
  (loop while (and *inspector-worker* (bt:thread-alive-p *inspector-worker*))
        do
    (sleep 0.25)
    (let ((timed *inspector-timed*)
          (worker *inspector-worker*))
      (when (and timed worker
                 (> (- (get-internal-real-time) (cdr timed))
                    (* *inspector-time-limit* internal-time-units-per-second)))
        (let ((token (car timed)))
          (ignore-errors
           (bt:interrupt-thread
            worker
            (lambda ()
              ;; Still the same piece of work?  If it finished in the moment
              ;; between the look and the interrupt, there is nothing to stop.
              (when (and *inspector-timed* (eq (car *inspector-timed*) token))
                (error 'inspector-timeout))))))))))

(defun inspector-worker-loop ()
  (loop
    (let ((job (bt:with-lock-held (*inspector-jobs-lock*)
                 (loop while (null *inspector-jobs*)
                       do (bt:condition-wait *inspector-jobs-ready* *inspector-jobs-lock*))
                 (let ((oldest (first (last *inspector-jobs*))))
                   (setf *inspector-jobs* (butlast *inspector-jobs*))
                   oldest))))
      ;; :STOP is how the thread is asked to end: by returning, of its own
      ;; accord.  A thread parked in that wait cannot be made to leave it --
      ;; see "Interrupt needs two mechanisms" in CLAUDE.md -- and ECL, asked
      ;; to quit with one there, waits for it for good.
      (when (eq job :stop)
        (return))
      (handler-case (funcall job)
        (error (condition)
          (note "inspector: ~a" condition))))))

(defun stop-inspector-worker ()
  "Ask the worker to end, and wait a moment for it to.  For a process about to
exit; the next job starts another."
  (let ((worker *inspector-worker*))
    (when (and worker (bt:thread-alive-p worker))
      (bt:with-lock-held (*inspector-jobs-lock*)
        (push :stop *inspector-jobs*)
        (bt:condition-notify *inspector-jobs-ready*))
      (loop repeat 50
            while (or (bt:thread-alive-p worker)
                      (and *inspector-watchdog* (bt:thread-alive-p *inspector-watchdog*)))
            do (sleep 0.1)))
    (setf *inspector-worker* nil)))

(defun run-on-worker (function)
  "Call FUNCTION on the inspector's thread -- or here and now, when there is no
main thread to hand the result to, which is what makes `make test' able to ask
and then look."
  (cond ((and (null *main-thread-target*) (not (eq *inspector-worker-mode* t)))
         (funcall function))
        (t
         (bt:with-lock-held (*inspector-jobs-lock*)
           (unless (and *inspector-worker* (bt:thread-alive-p *inspector-worker*))
             (setf *inspector-worker*
                   (bt:make-thread #'inspector-worker-loop :name "lisp listener inspector")))
           (unless (and *inspector-watchdog* (bt:thread-alive-p *inspector-watchdog*))
             (setf *inspector-watchdog*
                   (bt:make-thread #'inspector-watchdog-loop
                                   :name "lisp listener inspector watchdog")))
           (push function *inspector-jobs*)
           (bt:condition-notify *inspector-jobs-ready*))))
  (values))

(defvar *inspector* nil
  "The inspector whose work is being done, for what a control's function or a
view may want of it: INSPECTOR:OPEN-OBJECT.")

(defun call-in-object-thread (inspector function)
  "Call FUNCTION where INSPECTOR's object wants to be touched: on thread 1 for
an Objective-C object -- AppKit and UIKit want theirs touched nowhere else --
waiting for it; and here, on the worker, for everything else."
  (if (and *main-thread-target* (objc-object-p (inspector-object inspector)))
      (on-main-thread (:wait t) (funcall function))
      (funcall function)))

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
             ;; Where the object is NOW; the action may walk somewhere else,
             ;; and the model is then computed where that wants to be.
             (call-in-object-thread
              inspector
              (lambda ()
                (handler-case
                    (let ((*package* (or (inspector-package inspector) *package*))
                          (*inspector* inspector))
                      (with-time-limit () (funcall action)))
                  (error (condition)
                    (setf (inspector-message inspector) (report-condition condition)))))))
           (deliver-model inspector
                          (call-in-object-thread
                           inspector
                           (lambda ()
                             (let ((*inspector* inspector))
                               (compute-model inspector)))))))
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

(defun row-cell (row &optional column)
  "Which cell of ROW is meant: COLUMN, if that cell is a place, and otherwise
the row's last place -- its value, in the usual row of a name and a value.
NIL when the row has no place at all."
  (and row
       (if (and column (nth column (row-places row)))
           column
           (position-if-not #'null (row-places row) :from-end t))))

(defun row-place (row &optional column)
  "The place ROW is about, or the one in its cell COLUMN."
  (let ((cell (row-cell row column)))
    (and cell (nth cell (row-places row)))))

(defun row-editable-p (row &optional column)
  (let ((cell (row-cell row column)))
    (and cell (nth cell (row-editable row)))))

(defun row-removable-p (row &optional column)
  (let ((cell (row-cell row column)))
    (and cell (nth cell (row-removable row)))))

(defun inspector-open-row (inspector pane index &optional column)
  "Walk into row INDEX of PANE -- into its cell COLUMN, if that is given and is
a place: the inspector now looks at that value."
  (let* ((row (inspector-pane-row inspector pane index))
         (place (row-place row column)))
    (when place
      (inspector-update
       inspector
       (lambda ()
         (let ((value (inspector:place-value place)))
           (walk-into inspector value
                      (or (inspector:place-label place)
                          (let ((label (first (row-cells row))))
                            (and (stringp label) (plusp (length label)) label))))))))))

(defun inspector-open-object (inspector object &optional label)
  "Walk into OBJECT, from wherever INSPECTOR is."
  (inspector-update inspector (lambda () (walk-into inspector object label))))

(defun inspector:open-object (object &optional label)
  "Walk the inspector into OBJECT.  For a control's function -- a button that
leads somewhere -- which is called while an inspector is at work and has no
other way to say which."
  (unless *inspector*
    (error "There is no inspector at work to walk anywhere."))
  (walk-into *inspector* object label)
  object)

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

(defun inspector-edit-row (inspector pane index text &optional column)
  "Put the value of TEXT -- a form, read and evaluated -- at row INDEX of PANE,
in its cell COLUMN if that is given."
  (let ((place (row-place (inspector-pane-row inspector pane index) column)))
    (when place
      (inspector-update
       inspector
       (lambda ()
         (set-place-from-text place text)
         (note-changed-elsewhere inspector))))))

(defun inspector-remove-row (inspector pane index &optional column)
  "Take away what is at row INDEX of PANE: unbind the slot, drop the key."
  (let ((place (row-place (inspector-pane-row inspector pane index) column)))
    (when place
      (inspector-update
       inspector
       (lambda ()
         (unless (inspector:place-supports-p place :remove)
           (error "This cannot be removed."))
         (place-remove place)
         (note-changed-elsewhere inspector))))))

(defun inspector-insert-row (inspector pane index text &optional column)
  "Put the value of TEXT, a form, in BEFORE row INDEX of PANE: in a list, or a
vector that can grow."
  (let ((place (row-place (inspector-pane-row inspector pane index) column)))
    (when place
      (inspector-update
       inspector
       (lambda ()
         (unless (inspector:place-supports-p place :insert)
           (error "Nothing can be inserted here."))
         (when (zerop (length (string-trim " " (or text ""))))
           (error "There is no value to insert."))
         (place-insert place (eval (read-from-string text)))
         (note-changed-elsewhere inspector))))))

(defun row-insertable-p (row &optional column)
  (let ((cell (row-cell row column)))
    (and cell (nth cell (row-insertable row)))))

(defun inspector-add (inspector value-text &optional key-text)
  "Add to the object INSPECTOR is looking at: the value of VALUE-TEXT, a form,
under the value of KEY-TEXT where the object wants a key."
  (inspector-update
   inspector
   (lambda ()
     (let* ((object (inspector-object inspector))
            (kind (inspector:addition object)))
       (unless kind
         (error "Nothing can be added to this."))
       (flet ((evaluate (text what)
                (when (zerop (length (string-trim " " (or text ""))))
                  (error "There is no ~a to add." what))
                (eval (read-from-string text))))
         (if (eq kind :key-and-value)
             (inspector:add object (evaluate value-text "value") (evaluate key-text "key"))
             (inspector:add object (evaluate value-text "value"))))
       (note-changed-elsewhere inspector)))))

(defun inspector-add-line (inspector text)
  "Add to the object from ONE line of text: a form for the value -- or, where
the object wants a key, a form for the key and then one for the value.  For a
front end with one field to type in."
  (inspector-update
   inspector
   (lambda ()
     (let* ((object (inspector-object inspector))
            (kind (inspector:addition object))
            (text (string-trim '(#\Space #\Tab #\Newline) (or text ""))))
       (unless kind
         (error "Nothing can be added to this."))
       (when (zerop (length text))
         (error "There is nothing to add."))
       (if (eq kind :key-and-value)
           (multiple-value-bind (key end) (read-from-string text)
             (when (>= end (length text))
               (error "A key and then a value: two forms."))
             (inspector:add object (eval (read-from-string text t nil :start end)) (eval key)))
           (inspector:add object (eval (read-from-string text))))
       (note-changed-elsewhere inspector)))))

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
         (call-in-object-thread
          inspector
          (lambda ()
            (let ((*package* (or (inspector-package inspector) *package*)))
              (ensure-rows table (+ upto *inspector-row-chunk*)))))
         (deliver-model inspector model))))))

;;; What is under the pointer --------------------------------------------------------

(defun inspector-request-readout (inspector pane x y)
  "Ask what PANE's drawing has to say about the point (X, Y), in the canvas's
units.  The answer comes to SHOW-INSPECTOR-READOUT.  Asked many times as the
pointer moves, it is answered for where the pointer is, not for where it was."
  (let ((waiting (inspector-readout-request inspector)))
    (setf (inspector-readout-request inspector) (list pane x y))
    (unless waiting
      (run-on-worker
       (lambda ()
         (let ((request (shiftf (inspector-readout-request inspector) nil)))
           (when request
             (destructuring-bind (pane x y) request
               (let* ((model (inspector-model inspector))
                      (pane-model (and model (nth pane (model-panes model))))
                      (text (and pane-model
                                 (call-in-object-thread
                                  inspector
                                  (lambda ()
                                    (handler-case
                                        (with-time-limit ()
                                          (drawing-readout (pane-model-drawing pane-model)
                                                           x y))
                                      (error () nil)))))))
                 (cond (*main-thread-target*
                        (on-main-thread ()
                          (show-inspector-readout inspector pane text x y)))
                       (t (setf (inspector-readout inspector) text))))))))))))

(defun readout-shapes (text x y)
  "What to paint over a drawing to say TEXT about the point (X, Y): a crosshair
there and the words beside it, as the canvas's own shapes -- so that whatever
paints a drawing paints its readout too, on either toolkit."
  (drawing-scene-ops
   (inspector:drawing ()
     (canvas:pen 0.5)
     (canvas:color 1 1 1 0.5)
     ;; Past the edge of any view: the canvas's units are of its SHORTER side.
     (canvas:line -1000 y 1000 y)
     (canvas:line x -1000 x 1000)
     (when (and text (plusp (length text)))
       (let* ((size 7)
              (width (+ 5 (* 0.62 size (length text))))
              (left (if (> (+ x 4 width) 100) (- x 4 width) (+ x 4)))
              (bottom (if (> (+ y 16) 100) (- y 15) (+ y 4))))
         (canvas:color 0 0 0 0.8)
         (canvas:box left bottom width 11)
         (canvas:color :white)
         (canvas:text (+ left 2.5) (+ bottom 2) text size))))))

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
    (when (and (pane-model-native pane) (plusp (length (pane-model-native-text pane))))
      (format stream "~a~%" (pane-model-native-text pane)))
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

(defvar *inspected* :elsewhere
  "Inside an evaluation at a listener's prompt: a list of the object INSPECT
was last called on there, or NIL.  :ELSEWHERE everywhere else.

ECL's INSPECT answers its argument, where SBCL's answers nothing, and a
listener prints what a form answers: (inspect bytes) opened the inspector and
then printed all 256 of them under the prompt.  The listener looks here and
leaves out a value that is only the thing just inspected.")

(defun inspect-object (object &optional (listener *listener*))
  "Open an inspector on OBJECT: in a window where the front end has one, and
as text in the transcript where it has not.  Answers no values, so that what
was inspected is not printed again under it."
  (let ((inspector (make-inspector object listener)))
    (unless (eq *inspected* :elsewhere)
      (setf *inspected* (list object)))
    (cond ((and *main-thread-target* (inspector-capabilities))
           (bt:with-lock-held (*inspectors-lock*)
             (push inspector *inspectors*))
           (run-on-worker
            (lambda ()
              (let ((model (call-in-object-thread
                            inspector
                            (lambda ()
                              (let ((*inspector* inspector))
                                (compute-model inspector))))))
                (on-main-thread ()
                  (setf (inspector-model inspector) model)
                  (show-inspector inspector))))))
          (t (print-inspector inspector *standard-output*))))
  (values))

(defun inspector-closed (inspector)
  "INSPECTOR's window has gone.  Thread 1."
  (bt:with-lock-held (*inspectors-lock*)
    (setf *inspectors* (remove inspector *inspectors*)))
  ;; What it kept alive may go.
  (dolist (object (shiftf (inspector-retained-objects inspector) '()))
    (ignore-errors (objc:release (objc-object-pointer object))))
  inspector)
