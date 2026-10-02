;;;; src/macos/inspector-window.lisp -- the inspector's window.
;;;;
;;;; The Mac's half of src/inspector.lisp.  One window to an inspector:
;;;;
;;;;   - across the top, the PATH walked from where it started, a button a step;
;;;;   - two PANES side by side, each with a pop-up of the views that apply, a
;;;;     row of controls made from the chosen view's options, and whatever the
;;;;     view's scene comes to: a drawing, a table, some text;
;;;;   - down the right, the OBJECT panel: what it is, the row selected and a
;;;;     field to change it, the controls contributed for it, and the views
;;;;     that apply and who contributed each;
;;;;   - and, from All Views…, a SHEET of every view there is, those that do
;;;;     not apply included, each saying why not.
;;;;
;;;; NOTHING HERE EVALUATES.  What is shown is the inspector's MODEL -- strings
;;;; and shapes the worker thread made -- and what the person does is passed
;;;; back as a request (INSPECTOR-SELECT-VIEW, INSPECTOR-OPEN-ROW, ...), whose
;;;; answer is a new model and another call to REFRESH-INSPECTOR.  A table asks
;;;; for a row and gets its text out of the model; a row not computed yet is
;;;; asked for and shows as an ellipsis until it comes.
;;;;
;;;; A drawing is painted by the canvas's own painter (PAINT-SHAPES, in
;;;; src/canvas.lisp): a view's drawing is a list of the canvas's shapes.
;;;;
;;;; Thread 1, all of it.

(in-package #:lisp-listener)

(defparameter *inspector-width* 1040d0)
(defparameter *inspector-height* 600d0)
(defparameter *inspector-panel-width* 250d0)
(defparameter *inspector-bar-height* 30d0)
(defparameter *inspector-margin* 8d0)
(defparameter *inspector-row-height* 17d0)
(defparameter *inspector-font-size* 11d0)

;;; NSAutoresizingMaskOptions.
(defconstant +ns-view-min-x-margin+ 1)
(defconstant +ns-view-width-sizable+ 2)
(defconstant +ns-view-min-y-margin+ 8)
(defconstant +ns-view-height-sizable+ 16)

(defun inspector-capabilities ()
  "A table, some text, a drawing, and a view of AppKit's own: everything a
scene can be."
  '(:table :text :drawing :native :appkit))

;;; The controllers ------------------------------------------------------------------
;;;
;;; One for the window -- the path, the object panel's controls, the close --
;;; and one for each pane, which is its table's data source and delegate and
;;; the target of its pop-up and its options.  Held by the inspector, since
;;; nothing in AppKit retains a target or a delegate.

(objc:define-objc-class inspector-window-controller ()
  ((inspector :initform nil :accessor controller-inspector))
  (:objc-class-name "LispListenerInspectorController"))

(objc:define-objc-class inspector-pane-controller ()
  ((inspector :initform nil :accessor pane-controller-inspector)
   (index :initform 0 :accessor pane-controller-index))
  (:objc-class-name "LispListenerInspectorPaneController"))

(defun inspector-part (inspector key)
  (getf (inspector-retained inspector) key))

(defun (setf inspector-part) (value inspector key)
  (setf (getf (inspector-retained inspector) key) value))

(defun inspector-pane-parts (inspector pane)
  (nth pane (inspector-part inspector :panes)))

(defun pane-model-of (inspector pane)
  (let ((model (inspector-model inspector)))
    (and model (nth pane (model-panes model)))))

;;; The drawing ----------------------------------------------------------------------

(objc:define-objc-class inspector-drawing-view ()
  ((scene :initform nil :accessor drawing-view-scene)
   (inspector :initform nil :accessor drawing-view-inspector)
   (pane :initform 0 :accessor drawing-view-pane)
   ;; Whether the pointer is over it, and what was last said about where it
   ;; is: (TEXT X Y), in the canvas's units.
   (inside :initform nil :accessor drawing-view-inside)
   (readout :initform nil :accessor drawing-view-readout))
  (:objc-class-name "LispListenerInspectorDrawing")
  (:objc-superclass-name "NSView"))

;;; Flipped, as the canvas's view is: one painter, y running down.
(objc:define-objc-method ("isFlipped" objc:objc-bool)
    ((self inspector-drawing-view))
  t)

(objc:define-objc-method ("drawRect:" :void)
    ((self inspector-drawing-view pointer) (dirty cocoa:ns-rect))
  (declare (ignorable dirty))
  (handler-case
      (let ((bounds (objc:invoke pointer "bounds"))
            (scene (drawing-view-scene self)))
        (paint-shapes (append (and scene (drawing-scene-ops scene))
                              ;; What is under the pointer, over the top.
                              (let ((readout (drawing-view-readout self)))
                                (and readout (apply #'readout-shapes readout))))
                      (or (and scene (drawing-scene-background scene))
                          *canvas-default-background*)
                      (aref bounds 2) (aref bounds 3)))
    (error (condition) (note "inspector drawRect: ~a" condition))))

;;; The pointer over a drawing asks what is under it.  The answer is the
;;; view's own READOUT function's, computed on the worker like everything of a
;;; view's, and comes back to SHOW-INSPECTOR-READOUT.  -mouseMoved: needs a
;;; tracking area; see BUILD-INSPECTOR-PANE.
(objc:define-objc-method ("mouseMoved:" :void)
    ((self inspector-drawing-view pointer) (event objc:objc-object-pointer))
  (handler-case
      (let* ((point (objc:invoke pointer "convertPoint:fromView:"
                                 (objc:invoke event "locationInWindow") nil))
             (bounds (objc:invoke pointer "bounds"))
             (canvas (canvas-point-from-view (aref point 0) (aref point 1)
                                             (aref bounds 2) (aref bounds 3)))
             (inspector (drawing-view-inspector self)))
        (setf (drawing-view-inside self) t)
        (when (and inspector (drawing-view-scene self)
                   (drawing-scene-readout (drawing-view-scene self)))
          (inspector-request-readout inspector (drawing-view-pane self)
                                     (car canvas) (cdr canvas))))
    (error (condition) (note "inspector mouseMoved: ~a" condition))))

(objc:define-objc-method ("mouseExited:" :void)
    ((self inspector-drawing-view pointer) (event objc:objc-object-pointer))
  (declare (ignorable event))
  (handler-case
      (progn (setf (drawing-view-inside self) nil
                   (drawing-view-readout self) nil)
             (objc:invoke pointer "setNeedsDisplay:" t))
    (error (condition) (note "inspector mouseExited: ~a" condition))))

(defun show-inspector-readout (inspector pane text x y)
  "Say TEXT at (X, Y) on PANE's drawing -- if the pointer is still over it: the
answer comes a moment after the question, and the pointer may have left."
  (let* ((parts (inspector-pane-parts inspector pane))
         (object (getf parts :drawing-object)))
    (when (and object (drawing-view-inside object)
               (live-pointer-p (inspector-part inspector :window)))
      (setf (drawing-view-readout object) (and text (list text x y)))
      (objc:invoke (getf parts :drawing) "setNeedsDisplay:" t)
      t)))

;;; A pane's table -------------------------------------------------------------------

(defmacro define-pane-method ((selector result-type &key on-error) (&rest argspecs) &body body)
  "A method of a pane's controller.  INSPECTOR, PANE and PANE-MODEL are bound;
nothing may unwind into AppKit."
  `(objc:define-objc-method (,selector ,result-type)
       ((self inspector-pane-controller) ,@argspecs)
     (declare (ignorable ,@(mapcar #'first argspecs)))
     (handler-case
         (let* ((inspector (pane-controller-inspector self))
                (pane (pane-controller-index self))
                (pane-model (and inspector (pane-model-of inspector pane))))
           (declare (ignorable inspector pane pane-model))
           ,@body)
       (error (condition)
         (note "inspector ~a: ~a" ,selector condition)
         ,on-error))))

(defun pane-table-model (pane-model)
  (and pane-model (pane-model-table pane-model)))

(define-pane-method ("numberOfRowsInTableView:" (:signed :long-long) :on-error 0)
    ((table objc:objc-object-pointer))
  (let ((model (pane-table-model pane-model)))
    (if model (table-model-count model) 0)))

(defun pane-row (inspector pane pane-model index)
  "Row INDEX of the pane's table, or NIL -- and then it is asked for, once for
each stretch of the table that is scrolled to."
  (let ((model (pane-table-model pane-model)))
    (when model
      (or (table-row model index)
          (let ((asked (or (getf (inspector-pane-parts inspector pane) :rows-asked) -1)))
            (when (> index asked)
              (setf (getf (nth pane (inspector-part inspector :panes)) :rows-asked)
                    (+ index *inspector-row-chunk*))
              (inspector-need-rows inspector pane index))
            nil)))))

(define-pane-method ("tableView:objectValueForTableColumn:row:" objc:objc-object-pointer
                     :on-error (cffi:null-pointer))
    ((table objc:objc-object-pointer)
     (column objc:objc-object-pointer)
     (index (:signed :long-long)))
  (let* ((row (pane-row inspector pane pane-model index))
         ;; A group row is asked for with no column at all.
         (cell (if (cffi:null-pointer-p column)
                   0
                   (objc:invoke (objc:invoke column "identifier") "integerValue"))))
    ;; Autoreleased: an object a Lisp method answers is the caller's to release.
    (objc:string-to-ns-string
     (cond ((null row) (if (zerop cell) "…" ""))
           (t (or (nth cell (row-cells row)) "")))
     t)))

(define-pane-method ("tableView:isGroupRow:" objc:objc-bool)
    ((table objc:objc-object-pointer) (index (:signed :long-long)))
  (let ((row (and (pane-table-model pane-model)
                  (table-row (pane-table-model pane-model) index))))
    (and row (row-header-p row) t)))

(define-pane-method ("tableView:shouldSelectRow:" objc:objc-bool)
    ((table objc:objc-object-pointer) (index (:signed :long-long)))
  (let ((row (and (pane-table-model pane-model)
                  (table-row (pane-table-model pane-model) index))))
    (and row (not (row-header-p row)) t)))

;;; Cells are never edited where they are: a double click walks in, and the
;;; object panel has the field that changes the selected row.
(define-pane-method ("tableView:shouldEditTableColumn:row:" objc:objc-bool)
    ((table objc:objc-object-pointer)
     (column objc:objc-object-pointer)
     (index (:signed :long-long)))
  nil)

(define-pane-method ("tableViewSelectionDidChange:" :void)
    ((notification objc:objc-object-pointer))
  ;; The row, and the COLUMN that was clicked: in a grid every cell is a place,
  ;; and the one meant is the one under the mouse.  A selection made from the
  ;; keyboard has no clicked column, and means the row's own place.
  (let ((table (getf (inspector-pane-parts inspector pane) :table)))
    (setf (inspector-part inspector :selection)
          (let ((index (objc:invoke table "selectedRow"))
                (column (objc:invoke table "clickedColumn")))
            (and (>= index 0) (list pane index (and (>= column 0) column)))))
    (show-inspector-selection inspector)))

(define-pane-method ("paneOpenRow:" :void) ((sender objc:objc-object-pointer))
  (let ((index (objc:invoke sender "clickedRow"))
        (column (objc:invoke sender "clickedColumn")))
    (when (>= index 0)
      (inspector-open-row inspector pane index (and (>= column 0) column)))))

(define-pane-method ("paneView:" :void) ((sender objc:objc-object-pointer))
  (let ((choice (nth (objc:invoke sender "indexOfSelectedItem")
                     (pane-model-choices pane-model))))
    (when choice
      (inspector-select-view inspector pane (car choice)))))

(defun option-control-value (control option)
  "What the option's control says now."
  (ecase (option-model-kind option)
    (:boolean (= 1 (objc:invoke control "state")))
    ((:integer :number) (objc:invoke control "doubleValue"))
    (:choice (nth (objc:invoke control "indexOfSelectedItem") (option-model-choices option)))))

(define-pane-method ("paneOption:" :void) ((sender objc:objc-object-pointer))
  (let ((option (nth (objc:invoke sender "tag") (pane-model-options pane-model))))
    (when option
      (inspector-set-option inspector pane (option-model-keyword option)
                            (option-control-value sender option)))))

;;; The window's own actions ---------------------------------------------------------

(defmacro define-inspector-method ((selector result-type &key on-error) (&rest argspecs)
                                   &body body)
  `(objc:define-objc-method (,selector ,result-type)
       ((self inspector-window-controller) ,@argspecs)
     (declare (ignorable ,@(mapcar #'first argspecs)))
     (handler-case
         (let ((inspector (controller-inspector self)))
           (declare (ignorable inspector))
           ,@body)
       (error (condition)
         (note "inspector ~a: ~a" ,selector condition)
         ,on-error))))

(define-inspector-method ("inspectorPath:" :void) ((sender objc:objc-object-pointer))
  (inspector-go-to inspector (objc:invoke sender "tag")))

(define-inspector-method ("inspectorRefresh:" :void) ((sender objc:objc-object-pointer))
  (inspector-refresh inspector))

(define-inspector-method ("inspectorControl:" :void) ((sender objc:objc-object-pointer))
  (let* ((index (objc:invoke sender "tag"))
         (control (nth index (model-controls (inspector-model inspector)))))
    (when control
      (inspector-set-control
       inspector index
       (ecase (control-model-kind control)
         (:slider (objc:invoke sender "doubleValue"))
         (:toggle (= 1 (objc:invoke sender "state")))
         (:field (objc:ns-string-to-string (objc:invoke sender "stringValue")))
         (:button nil))))))

(define-inspector-method ("inspectorEdit:" :void) ((sender objc:objc-object-pointer))
  (let ((selection (inspector-part inspector :selection)))
    (when selection
      (destructuring-bind (pane index column) selection
        (inspector-edit-row inspector pane index
                            (objc:ns-string-to-string (objc:invoke sender "stringValue"))
                            column)))))

(define-inspector-method ("inspectorRemove:" :void) ((sender objc:objc-object-pointer))
  (let ((selection (inspector-part inspector :selection)))
    (when selection
      (destructuring-bind (pane index column) selection
        (inspector-remove-row inspector pane index column)))))

(define-inspector-method ("inspectorInsert:" :void) ((sender objc:objc-object-pointer))
  ;; The value typed in the Add section's field, put in BEFORE the selected row.
  (let ((selection (inspector-part inspector :selection))
        (value (inspector-part inspector :add-value)))
    (when (and selection (live-pointer-p value))
      (destructuring-bind (pane index column) selection
        (inspector-insert-row inspector pane index
                              (objc:ns-string-to-string (objc:invoke value "stringValue"))
                              column))
      (objc:invoke value "setStringValue:" ""))))

(define-inspector-method ("inspectorAdd:" :void) ((sender objc:objc-object-pointer))
  (let ((key (inspector-part inspector :add-key))
        (value (inspector-part inspector :add-value)))
    (when (live-pointer-p value)
      (inspector-add inspector
                     (objc:ns-string-to-string (objc:invoke value "stringValue"))
                     (and (live-pointer-p key)
                          (objc:ns-string-to-string (objc:invoke key "stringValue"))))
      ;; Emptied for the next one: adding is something done several times over.
      (objc:invoke value "setStringValue:" "")
      (when (live-pointer-p key)
        (objc:invoke key "setStringValue:" "")))))

(define-inspector-method ("windowWillClose:" :void) ((notification objc:objc-object-pointer))
  (let ((window (inspector-part inspector :window)))
    (when (live-pointer-p window)
      (setf (getf *remembered* :inspector) (window-frame-list window))
      (save-preferences)))
  (hide-views-sheet inspector)
  (inspector-closed inspector))

;;; Small pieces ---------------------------------------------------------------------

(defun inspector-font (&optional bold)
  (if bold
      (objc:invoke "NSFont" "boldSystemFontOfSize:" *inspector-font-size*)
      (objc:invoke "NSFont" "systemFontOfSize:" *inspector-font-size*)))

(defun inspector-mono-font ()
  (objc:invoke "NSFont" "monospacedSystemFontOfSize:weight:" *inspector-font-size* 0d0))

(defun make-inspector-label (text x y width &key bold secondary (height 16d0))
  "A label, autoreleased, pinned to the top of whatever it is put in."
  (let ((label (objc:invoke "NSTextField" "labelWithString:" text)))
    (objc:invoke label "setFrame:" (vector x y width height))
    (objc:invoke label "setFont:" (inspector-font bold))
    (objc:invoke (objc:invoke label "cell") "setLineBreakMode:" 4) ; truncating tail
    (when secondary
      (objc:invoke label "setTextColor:" (objc:invoke "NSColor" "secondaryLabelColor")))
    (objc:invoke label "setAutoresizingMask:" +ns-view-min-y-margin+)
    label))

(defun remove-subviews (view)
  (let ((subviews (objc:invoke (objc:invoke view "subviews") "copy")))
    (dotimes (index (objc:invoke subviews "count"))
      (objc:invoke (objc:invoke subviews "objectAtIndex:" index) "removeFromSuperview"))
    (objc:release subviews)))

(defun view-height (view)
  (aref (objc:invoke view "bounds") 3))

(defun view-width (view)
  (aref (objc:invoke view "bounds") 2))

(defun make-plain-view (frame mask)
  "An NSView (+1) with FRAME and autoresizing MASK."
  (let ((view (objc:invoke (objc:invoke "NSView" "alloc") "initWithFrame:" frame)))
    (objc:invoke view "setAutoresizingMask:" mask)
    view))

;;; Building a pane ------------------------------------------------------------------

(defun make-inspector-table (controller frame)
  "The pane's table in its scroll view.  Answers the scroll view (+1) and the table."
  (let* ((scroll (objc:invoke (objc:invoke "NSScrollView" "alloc") "initWithFrame:" frame))
         (table (objc:invoke (objc:invoke "NSTableView" "alloc") "initWithFrame:" frame)))
    (objc:invoke table "setRowHeight:" *inspector-row-height*)
    (objc:invoke table "setUsesAlternatingRowBackgroundColors:" t)
    (objc:invoke table "setAllowsMultipleSelection:" nil)
    ;; A column's position is the cell it shows, which the selection relies on.
    (objc:invoke table "setAllowsColumnReordering:" nil)
    (objc:invoke table "setColumnAutoresizingStyle:" 4) ; the last column takes the slack
    (objc:invoke table "setDataSource:" controller)
    (objc:invoke table "setDelegate:" controller)
    (objc:invoke table "setTarget:" controller)
    (objc:invoke table "setDoubleAction:" (objc:coerce-to-selector "paneOpenRow:"))
    (objc:invoke scroll "setHasVerticalScroller:" t)
    (objc:invoke scroll "setHasHorizontalScroller:" t)
    (objc:invoke scroll "setAutohidesScrollers:" t)
    (objc:invoke scroll "setBorderType:" 0)
    (objc:invoke scroll "setDocumentView:" table)
    (objc:release table)
    (values scroll table)))

(defun make-inspector-text (frame)
  "A read-only text view in its scroll view.  Answers the scroll view (+1) and
the text view."
  (let* ((scroll (objc:invoke (objc:invoke "NSScrollView" "alloc") "initWithFrame:" frame))
         (text (objc:invoke (objc:invoke "NSTextView" "alloc") "initWithFrame:" frame)))
    (objc:invoke text "setEditable:" nil)
    (objc:invoke text "setSelectable:" t)
    (objc:invoke text "setFont:" (inspector-mono-font))
    (objc:invoke text "setAutoresizingMask:" +ns-view-width-sizable+)
    (objc:invoke text "setTextContainerInset:" (vector 6d0 6d0))
    (objc:invoke scroll "setHasVerticalScroller:" t)
    (objc:invoke scroll "setAutohidesScrollers:" t)
    (objc:invoke scroll "setBorderType:" 0)
    (objc:invoke scroll "setDocumentView:" text)
    (objc:release text)
    (values scroll text)))

(defun build-inspector-pane (inspector index frame)
  "One pane: the pop-up of views, the options bar, and room for a drawing, a
table and text.  Answers its view (+1) and a plist of its parts."
  (let* ((controller (make-instance 'inspector-pane-controller))
         (target (objc:objc-object-pointer controller))
         (width (aref frame 2)) (height (aref frame 3))
         (bar *inspector-bar-height*)
         (pane (make-plain-view frame (logior +ns-view-width-sizable+ +ns-view-height-sizable+)))
         (popup (objc:invoke (objc:invoke "NSPopUpButton" "alloc") "initWithFrame:pullsDown:"
                             (vector 6d0 (- height bar -3d0) 170d0 24d0) nil))
         ;; A row of its own under the pop-up: three sliders do not fit beside it.
         (options (make-plain-view (vector 0d0 (- height bar bar) width bar)
                                   (logior +ns-view-width-sizable+ +ns-view-min-y-margin+)))
         (content-frame (vector 0d0 0d0 width (- height bar)))
         (content (make-plain-view content-frame
                                   (logior +ns-view-width-sizable+ +ns-view-height-sizable+)))
         (drawing-object (make-instance 'inspector-drawing-view
                                        :init-function
                                        (lambda (pointer &rest initargs)
                                          (declare (ignore initargs))
                                          (objc:invoke pointer "initWithFrame:" content-frame))
                                        :allow-other-keys t))
         (drawing (objc:objc-object-pointer drawing-object))
         ;; Where a NATIVE scene's view goes: an NSImageView, say.
         (native-host (make-plain-view content-frame
                                       (logior +ns-view-width-sizable+
                                               +ns-view-height-sizable+))))
    (setf (pane-controller-inspector controller) inspector
          (pane-controller-index controller) index)
    (objc:invoke popup "setAutoresizingMask:" +ns-view-min-y-margin+)
    (objc:invoke popup "setFont:" (inspector-font))
    (objc:invoke popup "setTarget:" target)
    (objc:invoke popup "setAction:" (objc:coerce-to-selector "paneView:"))
    (objc:invoke pane "addSubview:" popup)
    (objc:invoke pane "addSubview:" options)
    (objc:invoke pane "addSubview:" content)
    (multiple-value-bind (table-scroll table) (make-inspector-table target content-frame)
      (multiple-value-bind (text-scroll text) (make-inspector-text content-frame)
        (setf (drawing-view-inspector drawing-object) inspector
              (drawing-view-pane drawing-object) index)
        ;; For -mouseMoved: and -mouseExited: -- NSTrackingMouseEnteredAndExited
        ;; (1), NSTrackingMouseMoved (2), NSTrackingActiveAlways (#x80), since a
        ;; readout should not want a click on the window first, and
        ;; NSTrackingInVisibleRect (#x200), so the area is the view at any size.
        (let ((area (objc:invoke (objc:invoke "NSTrackingArea" "alloc")
                                 "initWithRect:options:owner:userInfo:"
                                 content-frame (logior #x01 #x02 #x80 #x200) drawing nil)))
          (objc:invoke drawing "addTrackingArea:" area)
          (objc:release area))
        (objc:invoke content "addSubview:" drawing)
        (objc:invoke content "addSubview:" native-host)
        (objc:invoke content "addSubview:" table-scroll)
        (objc:invoke content "addSubview:" text-scroll)
        (objc:release native-host)
        (objc:release popup)
        (objc:release options)
        (objc:release content)
        (objc:release table-scroll)
        (objc:release text-scroll)
        (values pane
                (list :controller controller :view pane :popup popup :options options
                      :content content :drawing drawing :drawing-object drawing-object
                      :native-host native-host
                      :table table :table-scroll table-scroll
                      :text text :text-scroll text-scroll
                      :option-controls '() :option-signature nil :rows-asked -1))))))

;;; Showing a pane's model -----------------------------------------------------------

(defun set-table-columns (table pane-model)
  "Give TABLE a column for each cell its rows have, titled as the scene says."
  (let* ((model (pane-model-table pane-model))
         (titles (table-model-columns model))
         (wanted (max 1
                      (length titles)
                      (loop for index below (min 40 (table-model-count model))
                            for row = (table-row model index)
                            maximize (if (and row (not (row-header-p row)))
                                         (length (row-cells row))
                                         0))))
         (columns (objc:invoke table "tableColumns"))
         (have (objc:invoke columns "count")))
    (loop while (> have wanted)
          do (objc:invoke table "removeTableColumn:" (objc:invoke columns "lastObject"))
             (setf columns (objc:invoke table "tableColumns"))
             (decf have))
    (loop while (< have wanted)
          do (let ((column (objc:invoke (objc:invoke "NSTableColumn" "alloc")
                                        "initWithIdentifier:" (format nil "~d" have))))
               (objc:invoke column "setWidth:" (if (zerop have) 110d0 170d0))
               (objc:invoke (objc:invoke column "dataCell") "setFont:" (inspector-mono-font))
               (objc:invoke (objc:invoke column "dataCell") "setLineBreakMode:" 4)
               (objc:invoke column "setEditable:" nil)
               (objc:invoke table "addTableColumn:" column)
               (objc:release column)
               (incf have)))
    (let ((columns (objc:invoke table "tableColumns")))
      (dotimes (index wanted)
        (let ((column (objc:invoke columns "objectAtIndex:" index))
              ;; As wide as the longest cell computed so far, within reason: a
              ;; column of offsets and a column of sixteen bytes are not the
              ;; same width, and a fixed one cut the bytes off at eight.
              (longest (loop for row-index below (min 60 (table-model-count model))
                             for row = (table-row model row-index)
                             maximize (if (and row (not (row-header-p row)))
                                          (length (or (nth index (row-cells row)) ""))
                                          0))))
          (objc:invoke (objc:invoke column "headerCell")
                       "setStringValue:" (or (nth index titles) ""))
          (objc:invoke column "setWidth:"
                       (max 50d0
                            (min 460d0
                                 (+ 14d0 (* 6.7d0 (max longest
                                                       (length (or (nth index titles) ""))))))))))
      (objc:invoke table "sizeLastColumnToFit"))))

(defun build-option-controls (parts pane-model)
  "The options bar for the pane's view: a control for each option, tagged with
its position.  Answers the controls, in the options' order."
  (let ((bar (getf parts :options))
        (target (objc:objc-object-pointer (getf parts :controller)))
        (action (objc:coerce-to-selector "paneOption:"))
        (x 8d0)
        (controls '()))
    (remove-subviews bar)
    (loop for option in (pane-model-options pane-model)
          for tag from 0
          do (let ((control
                     (ecase (option-model-kind option)
                       (:boolean
                        (let ((box (objc:invoke "NSButton" "checkboxWithTitle:target:action:"
                                                (option-model-label option) target action)))
                          (let ((width (+ 30d0 (* 6.4d0 (length (option-model-label option))))))
                            (objc:invoke box "setFrame:" (vector x 5d0 width 20d0))
                            (objc:invoke box "setFont:" (inspector-font))
                            (incf x (+ width 8d0)))
                          box))
                       ((:integer :number)
                        (let ((width (+ 8d0 (* 6.4d0 (length (option-model-label option))))))
                          (objc:invoke bar "addSubview:"
                                       (make-inspector-label (option-model-label option)
                                                             x 7d0 width :secondary t))
                          (incf x width))
                        (let ((slider (objc:invoke
                                       "NSSlider" "sliderWithValue:minValue:maxValue:target:action:"
                                       (float (or (option-model-value option) 0) 1d0)
                                       (float (or (option-model-min option) 0) 1d0)
                                       (float (or (option-model-max option) 100) 1d0)
                                       target action)))
                          (objc:invoke slider "setFrame:" (vector x 5d0 70d0 20d0))
                          (objc:invoke slider "setControlSize:" 1) ; small
                          (incf x 80d0)
                          slider))
                       (:choice
                        (let ((width (+ 8d0 (* 6.4d0 (length (option-model-label option))))))
                          (objc:invoke bar "addSubview:"
                                       (make-inspector-label (option-model-label option)
                                                             x 7d0 width :secondary t))
                          (incf x width))
                        (let ((popup (objc:autorelease
                                      (objc:invoke (objc:invoke "NSPopUpButton" "alloc")
                                                   "initWithFrame:pullsDown:"
                                                   (vector x 3d0 92d0 24d0) nil))))
                          (dolist (choice (option-model-choices option))
                            (objc:invoke popup "addItemWithTitle:"
                                         (string-downcase (princ-to-string choice))))
                          (objc:invoke popup "setFont:" (inspector-font))
                          (objc:invoke popup "setTarget:" target)
                          (objc:invoke popup "setAction:" action)
                          (incf x 98d0)
                          popup)))))
               (objc:invoke control "setTag:" tag)
               (objc:invoke bar "addSubview:" control)
               (push control controls)))
    (nreverse controls)))

(defun set-option-control (control option)
  (ecase (option-model-kind option)
    (:boolean (objc:invoke control "setState:" (if (option-model-value option) 1 0)))
    ((:integer :number)
     (objc:invoke control "setDoubleValue:" (float (or (option-model-value option) 0) 1d0)))
    (:choice
     (objc:invoke control "selectItemAtIndex:"
                  (or (position (option-model-value option) (option-model-choices option)) 0)))))

(defun layout-pane-content (parts pane-model)
  "Share the pane's room among what its scene has: a drawing over a table over
text, each present one getting a part and an absent one hidden."
  (let* ((content (getf parts :content))
         (pane (getf parts :view))
         (width (view-width pane))
         ;; Under the pop-up, and under the options when the view has any.
         (height (- (view-height pane) *inspector-bar-height*
                    (if (pane-model-options pane-model) *inspector-bar-height* 0d0)))
         (drawing (and (pane-model-drawing pane-model) (getf parts :drawing)))
         (native (and (pane-model-native pane-model) (getf parts :native-host)))
         (table (and (pane-model-table pane-model) (getf parts :table-scroll)))
         (text (and (plusp (length (pane-model-text pane-model))) (getf parts :text-scroll)))
         (present (remove nil (list drawing native table text)))
         ;; Weights: a picture wants the most room, a note under one the least.
         (weights (mapcar (lambda (view)
                            (cond ((or (eq view drawing) (eq view native)) 3)
                                  ((eq view table) 2)
                                  (t (if (or drawing native table) 1 2))))
                          present))
         (total (reduce #'+ weights))
         (top height))
    (objc:invoke content "setFrame:" (vector 0d0 0d0 width height))
    (objc:invoke (getf parts :options) "setHidden:" (null (pane-model-options pane-model)))
    (dolist (view (list (getf parts :drawing) (getf parts :native-host)
                        (getf parts :table-scroll) (getf parts :text-scroll)))
      (objc:invoke view "setHidden:" (not (member view present))))
    (loop for view in present
          for weight in weights
          for share = (* height (/ weight total))
          do (decf top share)
             (objc:invoke view "setFrame:" (vector 0d0 (float top 1d0) width (float share 1d0)))
             (objc:invoke view "setAutoresizingMask:"
                          (logior +ns-view-width-sizable+ +ns-view-height-sizable+
                                  +ns-view-min-y-margin+ 32)))))

(defun refresh-inspector-pane (inspector index)
  (let* ((parts (inspector-pane-parts inspector index))
         (pane-model (pane-model-of inspector index))
         (view (getf parts :view)))
    (objc:invoke view "setHidden:" (null pane-model))
    (when pane-model
      ;; The pop-up of views.
      (let ((popup (getf parts :popup)))
        (objc:invoke popup "removeAllItems")
        (dolist (choice (pane-model-choices pane-model))
          (objc:invoke popup "addItemWithTitle:" (cdr choice)))
        (objc:invoke popup "selectItemAtIndex:"
                     (or (position (pane-model-view-name pane-model)
                                   (pane-model-choices pane-model) :key #'car)
                         0)))
      ;; The options: made again when the view changes, and only told their
      ;; values when it has not -- a slider made again in the middle of a drag
      ;; is a slider let go of.
      (let ((signature (cons (pane-model-view-name pane-model)
                             (mapcar #'option-model-keyword (pane-model-options pane-model)))))
        (if (equal signature (getf parts :option-signature))
            (loop for control in (getf parts :option-controls)
                  for option in (pane-model-options pane-model)
                  do (set-option-control control option))
            (let ((controls (build-option-controls parts pane-model)))
              (setf (getf (nth index (inspector-part inspector :panes)) :option-controls)
                    controls
                    (getf (nth index (inspector-part inspector :panes)) :option-signature)
                    signature)
              (loop for control in controls
                    for option in (pane-model-options pane-model)
                    do (set-option-control control option)))))
      ;; What the scene came to.
      (layout-pane-content parts pane-model)
      (let ((object (getf parts :drawing-object)))
        (setf (drawing-view-scene object) (pane-model-drawing pane-model))
        ;; What was said about the point under the pointer was said of the old
        ;; drawing: ask again of this one.
        (let ((readout (shiftf (drawing-view-readout object) nil)))
          (when (and readout (pane-model-drawing pane-model) (drawing-view-inside object))
            (inspector-request-readout inspector index (second readout) (third readout)))))
      (objc:invoke (getf parts :drawing) "setNeedsDisplay:" t)
      ;; A native scene's view: made now, here, by the function the view
      ;; answered, and put in the room laid out for it.
      (let ((host (getf parts :native-host)))
        (remove-subviews host)
        (when (pane-model-native pane-model)
          (let ((native (handler-case (funcall (pane-model-native pane-model))
                          (error (condition)
                            (note "inspector: a native view: ~a" condition)
                            nil))))
            (when (live-pointer-p native)
              (objc:invoke native "setFrame:" (objc:invoke host "bounds"))
              (objc:invoke native "setAutoresizingMask:"
                           (logior +ns-view-width-sizable+ +ns-view-height-sizable+))
              (objc:invoke host "addSubview:" native)))))
      (when (pane-model-table pane-model)
        (let* ((table (getf parts :table))
               (selected (objc:invoke table "selectedRow")))
          (set-table-columns table pane-model)
          (objc:invoke table "reloadData")
          (when (and (>= selected 0) (< selected (table-model-count (pane-model-table pane-model))))
            (select-restart-row table selected))))
      (objc:invoke (getf parts :text) "setString:" (pane-model-text pane-model)))))

;;; The path, and the object panel ---------------------------------------------------

(defun refresh-inspector-path (inspector)
  (let* ((bar (inspector-part inspector :path-bar))
         (target (objc:objc-object-pointer (inspector-part inspector :controller)))
         (steps (model-path (inspector-model inspector)))
         (x 6d0))
    (remove-subviews bar)
    (loop for label in steps
          for depth from 0
          do (when (plusp depth)
               (objc:invoke bar "addSubview:" (make-inspector-label "›" x 7d0 12d0 :secondary t))
               (incf x 12d0))
             (let* ((button (objc:invoke "NSButton" "buttonWithTitle:target:action:"
                                         (clip-string label 28) target
                                         (objc:coerce-to-selector "inspectorPath:")))
                    (width (+ 22d0 (* 6.6d0 (length (clip-string label 28))))))
               (objc:invoke button "setBezelStyle:" 15) ; inline
               (objc:invoke button "setFont:" (inspector-font (= depth (1- (length steps)))))
               (objc:invoke button "setFrame:" (vector x 5d0 width 20d0))
               (objc:invoke button "setTag:" depth)
               (objc:invoke bar "addSubview:" button)
               (incf x (+ width 4d0))))))

(defun build-control-view (control index target x y width)
  "The control for CONTROL, a CONTROL-MODEL, at Y in the object panel.
Answers the view that holds its value, and how much height it took."
  (let ((action (objc:coerce-to-selector "inspectorControl:"))
        (panel-mask +ns-view-min-y-margin+))
    (flet ((finish (view)
             (objc:invoke view "setTag:" index)
             (objc:invoke view "setEnabled:" (and (control-model-enabled control) t))
             (objc:invoke view "setAutoresizingMask:" panel-mask)
             view))
      (ecase (control-model-kind control)
        (:slider
         (let ((slider (objc:invoke "NSSlider" "sliderWithValue:minValue:maxValue:target:action:"
                                    0d0 (float (control-model-min control) 1d0)
                                    (float (control-model-max control) 1d0) target action)))
           (objc:invoke slider "setFrame:" (vector (+ x 84d0) y (- width 84d0) 20d0))
           (objc:invoke slider "setControlSize:" 1)
           (values (finish slider) 24d0 t)))
        (:toggle
         (let ((box (objc:invoke "NSButton" "checkboxWithTitle:target:action:"
                                 (control-model-label control) target action)))
           (objc:invoke box "setFrame:" (vector x y width 20d0))
           (objc:invoke box "setFont:" (inspector-font))
           (values (finish box) 24d0 nil)))
        (:field
         (let ((field (objc:invoke "NSTextField" "textFieldWithString:" "")))
           (objc:invoke field "setFrame:" (vector (+ x 84d0) y (- width 84d0) 20d0))
           (objc:invoke field "setFont:" (inspector-mono-font))
           (objc:invoke field "setTarget:" target)
           (objc:invoke field "setAction:" action)
           (values (finish field) 26d0 t)))
        (:button
         (let ((button (objc:invoke "NSButton" "buttonWithTitle:target:action:"
                                    (control-model-label control) target action)))
           (objc:invoke button "setFrame:" (vector x (- y 4d0) (min width 130d0) 26d0))
           (objc:invoke button "setFont:" (inspector-font))
           (values (finish button) 30d0 nil)))))))

(defun set-control-view (view control)
  (let ((value (control-model-value control)))
    (ecase (control-model-kind control)
      (:slider (when (realp value) (objc:invoke view "setDoubleValue:" (float value 1d0))))
      (:toggle (objc:invoke view "setState:" (if value 1 0)))
      (:field (objc:invoke view "setStringValue:" (inspector-print value 80)))
      (:button nil))))

(defun show-inspector-selection (inspector)
  "Put the selected row's value in the object panel's field, to be changed --
or say that it cannot be."
  (let* ((field (inspector-part inspector :editor))
         (caption (inspector-part inspector :editor-caption))
         (remove (inspector-part inspector :remove-button))
         (insert (inspector-part inspector :insert-button))
         (selection (inspector-part inspector :selection))
         (row (and selection (inspector-pane-row inspector (first selection)
                                                 (second selection))))
         (column (third selection))
         (cell (row-cell row column)))
    (when (live-pointer-p field)
      (cond (cell
             (let ((place (nth cell (row-places row))))
               (objc:invoke caption "setStringValue:"
                            (format nil "~a~:[ (read-only)~;~]"
                                    (clip-string (or (inspector:place-label place)
                                                     (first (row-cells row))
                                                     "")
                                                 30)
                                    (row-editable-p row column))))
             (objc:invoke field "setStringValue:" (or (nth cell (row-cells row)) ""))
             (objc:invoke field "setEnabled:" (and (row-editable-p row column) t))
             (when (live-pointer-p remove)
               (objc:invoke remove "setEnabled:" (and (row-removable-p row column) t)))
             (when (live-pointer-p insert)
               (objc:invoke insert "setEnabled:" (and (row-insertable-p row column) t))))
            (t
             (objc:invoke caption "setStringValue:" "No row selected")
             (objc:invoke field "setStringValue:" "")
             (objc:invoke field "setEnabled:" nil)
             (when (live-pointer-p remove)
               (objc:invoke remove "setEnabled:" nil))
             (when (live-pointer-p insert)
               (objc:invoke insert "setEnabled:" nil)))))))

(defun refresh-inspector-panel (inspector)
  "The object panel, laid out downwards from its top: what the object is, the
selected row and its field, the contributed controls, and the views."
  (let* ((panel (inspector-part inspector :panel))
         (target (objc:objc-object-pointer (inspector-part inspector :controller)))
         (model (inspector-model inspector))
         (width (- (view-width panel) (* 2 *inspector-margin*)))
         (x *inspector-margin*)
         (y (- (view-height panel) *inspector-margin*))
         (signature (mapcar (lambda (control)
                              (list (control-model-kind control) (control-model-label control)
                                    (control-model-group control)))
                            (model-controls model))))
    (cond
      ;; The same controls as last time: only their values are told.  They are
      ;; not made again, because one of them may be in the middle of a drag.
      ((and (equal signature (inspector-part inspector :control-signature))
            (equal (model-about model) (inspector-part inspector :about-shown))
            (equal (model-views model) (inspector-part inspector :views-shown))
            (eq (model-addition model) (inspector-part inspector :addition-shown)))
       (loop for view in (inspector-part inspector :control-views)
             for control in (model-controls model)
             do (set-control-view view control)))
      (t
       (remove-subviews panel)
       (flet ((label (text &rest keys)
                (decf y 18d0)
                (objc:invoke panel "addSubview:"
                             (apply #'make-inspector-label text x y width keys)))
              (gap () (decf y 8d0)))
         (label "Object" :bold t)
         (loop for (name . value) in (model-about model)
               do (label (format nil "~a: ~a" name value)))
         (gap)
         (label "Selected" :bold t)
         (decf y 18d0)
         (let ((caption (make-inspector-label "No row selected" x y width :secondary t)))
           (objc:invoke panel "addSubview:" caption)
           (setf (inspector-part inspector :editor-caption) caption))
         (decf y 24d0)
         ;; The field that changes the selected row, and beside it the button
         ;; that takes the row away, where a row can be: a slot unbound, a key
         ;; dropped.
         (let ((field (objc:invoke "NSTextField" "textFieldWithString:" ""))
               (remove (objc:invoke "NSButton" "buttonWithTitle:target:action:"
                                    "Remove" target
                                    (objc:coerce-to-selector "inspectorRemove:"))))
           (objc:invoke field "setFrame:" (vector x y (- width 76d0) 21d0))
           (objc:invoke field "setFont:" (inspector-mono-font))
           (objc:invoke field "setTarget:" target)
           (objc:invoke field "setAction:" (objc:coerce-to-selector "inspectorEdit:"))
           (objc:invoke field "setAutoresizingMask:" +ns-view-min-y-margin+)
           (objc:invoke field "setEnabled:" nil)
           (objc:invoke panel "addSubview:" field)
           (objc:invoke remove "setFrame:" (vector (+ x (- width 72d0)) (- y 4d0) 76d0 28d0))
           (objc:invoke remove "setFont:" (inspector-font))
           (objc:invoke remove "setAutoresizingMask:" +ns-view-min-y-margin+)
           (objc:invoke remove "setEnabled:" nil)
           (objc:invoke panel "addSubview:" remove)
           (setf (inspector-part inspector :editor) field
                 (inspector-part inspector :remove-button) remove))
         ;; Adding, where the object is something that can be added to: a key
         ;; and a value for a hash table, a value for a list or a vector that
         ;; grows.  Each field takes a form.
         (setf (inspector-part inspector :add-key) nil
               (inspector-part inspector :add-value) nil
               (inspector-part inspector :insert-button) nil)
         (when (model-addition model)
           (gap)
           (label (if (eq (model-addition model) :key-and-value)
                      "Add an entry"
                      "Add an element")
                  :bold t)
           (flet ((add-field (placeholder key)
                    (decf y 26d0)
                    (let ((field (objc:invoke "NSTextField" "textFieldWithString:" "")))
                      (objc:invoke field "setFrame:" (vector x y (- width 76d0) 21d0))
                      (objc:invoke field "setFont:" (inspector-mono-font))
                      (objc:invoke field "setPlaceholderString:" placeholder)
                      (objc:invoke field "setAutoresizingMask:" +ns-view-min-y-margin+)
                      (objc:invoke panel "addSubview:" field)
                      (setf (inspector-part inspector key) field)
                      field)))
             (when (eq (model-addition model) :key-and-value)
               (add-field "key" :add-key))
             (let ((value (add-field "value" :add-value))
                   (button (objc:invoke "NSButton" "buttonWithTitle:target:action:"
                                        "Add" target
                                        (objc:coerce-to-selector "inspectorAdd:"))))
               ;; Return in the value field adds, as the button does.
               (objc:invoke value "setTarget:" target)
               (objc:invoke value "setAction:" (objc:coerce-to-selector "inspectorAdd:"))
               (objc:invoke button "setFrame:" (vector (+ x (- width 72d0)) (- y 4d0) 76d0 28d0))
               (objc:invoke button "setFont:" (inspector-font))
               (objc:invoke button "setAutoresizingMask:" +ns-view-min-y-margin+)
               (objc:invoke panel "addSubview:" button)
               (setf (inspector-part inspector :add-button) button))
             ;; And in the middle, where there is a middle: the same value,
             ;; put in before the row selected.
             (when (eq (model-addition model) :value)
               (decf y 28d0)
               (let ((button (objc:invoke "NSButton" "buttonWithTitle:target:action:"
                                          "Insert Before Selected" target
                                          (objc:coerce-to-selector "inspectorInsert:"))))
                 (objc:invoke button "setFrame:" (vector (- x 4d0) (- y 4d0) 170d0 28d0))
                 (objc:invoke button "setFont:" (inspector-font))
                 (objc:invoke button "setAutoresizingMask:" +ns-view-min-y-margin+)
                 (objc:invoke button "setEnabled:" nil)
                 (objc:invoke panel "addSubview:" button)
                 (setf (inspector-part inspector :insert-button) button)))))
         (gap)
         (let ((views '()) (group nil))
           (loop for control in (model-controls model)
                 for index from 0
                 do (unless (equal group (control-model-group control))
                      (setf group (control-model-group control))
                      (gap)
                      (label (format nil "Controls · ~a" group) :bold t))
                    (decf y 24d0)
                    (multiple-value-bind (view height labelled)
                        (build-control-view control index target x y width)
                      (declare (ignore height))
                      (when labelled
                        (objc:invoke panel "addSubview:"
                                     (make-inspector-label (control-model-label control)
                                                           x (+ y 2d0) 80d0)))
                      (objc:invoke panel "addSubview:" view)
                      (set-control-view view control)
                      (push view views)))
           (setf (inspector-part inspector :control-views) (nreverse views)))
         (gap)
         (label "Views" :bold t)
         (loop for (title . contributor) in (model-views model)
               do (label (format nil "~a  —  ~a" title contributor) :secondary t))
         ;; Every view there is, these and the ones that do not apply.
         (decf y 30d0)
         (let ((button (objc:invoke "NSButton" "buttonWithTitle:target:action:"
                                    "All Views…" target
                                    (objc:coerce-to-selector "inspectorAllViews:"))))
           (objc:invoke button "setFrame:" (vector (- x 4d0) y 110d0 28d0))
           (objc:invoke button "setFont:" (inspector-font))
           (objc:invoke button "setAutoresizingMask:" +ns-view-min-y-margin+)
           (objc:invoke panel "addSubview:" button)
           (setf (inspector-part inspector :all-views-button) button)))
       (setf (inspector-part inspector :control-signature) signature
             (inspector-part inspector :about-shown) (model-about model)
             (inspector-part inspector :views-shown) (model-views model)
             (inspector-part inspector :addition-shown) (model-addition model))))
    (show-inspector-selection inspector)))

;;; Every view there is ---------------------------------------------------------------
;;;
;;; A sheet on the inspector's window: the views that apply, and under them the
;;; ones that do not, each saying why -- "needs (vector (unsigned-byte 8))" --
;;; which is how a person finds out that a view exists and what it wants.  One
;;; that applies can be put in either pane from here.  At the foot, what to
;;; type to contribute one for this kind of object.

(defparameter *views-sheet-width* 760d0)
(defparameter *views-sheet-height* 440d0)

(defun views-sheet-rows (inspector)
  "Every view, those that apply first; each the model's plist."
  (let ((model (inspector-model inspector)))
    (and model
         (stable-sort (copy-list (model-all-views model))
                      (lambda (a b) (and (getf a :applies) (not (getf b :applies))))))))

(defun views-sheet-cell (row column)
  (ecase column
    (0 (getf row :title))
    (1 (getf row :matches))
    (2 (getf row :contributor))
    (3 (format nil "~d" (getf row :priority)))
    (4 (if (getf row :applies) "Applies" (or (getf row :reason) "Does not apply.")))))

(defun views-sheet-selected (inspector)
  "The row of the sheet's table that is selected, or NIL."
  (let ((table (inspector-part inspector :sheet-table)))
    (and (live-pointer-p table)
         (let ((index (objc:invoke table "selectedRow")))
           (and (>= index 0) (nth index (inspector-part inspector :sheet-rows)))))))

(defun views-sheet-snippet (inspector)
  "What to type to contribute a view for what INSPECTOR is looking at."
  (format nil "(inspector:define-view (my-view :title \"Mine\" ~a)~%    (object)~%  (inspector:text \"~~a\" object))"
          (model-match (inspector-model inspector))))

(defun show-views-sheet-selection (inspector)
  "Say what the selected view is for, and offer it to the panes if it applies."
  (let ((row (views-sheet-selected inspector))
        (about (inspector-part inspector :sheet-about)))
    (when (live-pointer-p about)
      (objc:invoke about "setStringValue:"
                   (cond ((null row) "Select a view to see what it shows.")
                         (t (format nil "~a~@[  ~a~]"
                                    (clip-string (or (getf row :documentation)
                                                     "It does not say what it shows.")
                                                 200)
                                    (getf row :reason)))))
      (dolist (key '(:sheet-left :sheet-right))
        (objc:invoke (inspector-part inspector key) "setEnabled:"
                     (and row (getf row :applies) t))))))

(define-inspector-method ("numberOfRowsInTableView:" (:signed :long-long) :on-error 0)
    ((table objc:objc-object-pointer))
  (length (inspector-part inspector :sheet-rows)))

(define-inspector-method ("tableView:objectValueForTableColumn:row:" objc:objc-object-pointer
                          :on-error (cffi:null-pointer))
    ((table objc:objc-object-pointer)
     (column objc:objc-object-pointer)
     (index (:signed :long-long)))
  (let ((row (nth index (inspector-part inspector :sheet-rows))))
    (objc:string-to-ns-string
     (if row
         (views-sheet-cell row (objc:invoke (objc:invoke column "identifier") "integerValue"))
         "")
     t)))

;;; A view that does not apply is there to be read, and is greyed to say so.
(define-inspector-method ("tableView:willDisplayCell:forTableColumn:row:" :void)
    ((table objc:objc-object-pointer)
     (cell objc:objc-object-pointer)
     (column objc:objc-object-pointer)
     (index (:signed :long-long)))
  (let ((row (nth index (inspector-part inspector :sheet-rows))))
    (objc:invoke cell "setTextColor:"
                 (if (and row (getf row :applies))
                     (objc:invoke "NSColor" "labelColor")
                     (objc:invoke "NSColor" "secondaryLabelColor")))))

(define-inspector-method ("tableView:shouldEditTableColumn:row:" objc:objc-bool)
    ((table objc:objc-object-pointer)
     (column objc:objc-object-pointer)
     (index (:signed :long-long)))
  nil)

(define-inspector-method ("tableViewSelectionDidChange:" :void)
    ((notification objc:objc-object-pointer))
  (show-views-sheet-selection inspector))

(defun build-views-sheet (inspector)
  "The sheet: a table of every view, what the selected one is for, the two
buttons that put it in a pane, and how to add one.  Answers the panel (+1)."
  (let* ((width *views-sheet-width*) (height *views-sheet-height*)
         (margin 14d0)
         (target (objc:objc-object-pointer (inspector-part inspector :controller)))
         (panel (objc:invoke (objc:invoke "NSPanel" "alloc")
                             "initWithContentRect:styleMask:backing:defer:"
                             (vector 0d0 0d0 width height) +ns-window-style-titled+
                             +ns-backing-store-buffered+ nil))
         (content (objc:invoke panel "contentView"))
         (snippet-height 52d0)
         (buttons-y margin)
         (snippet-y (+ buttons-y 40d0))
         (about-y (+ snippet-y snippet-height 22d0))
         (table-y (+ about-y 40d0))
         (table-frame (vector margin table-y (- width (* 2 margin))
                              (- height table-y margin 22d0)))
         (scroll (objc:invoke (objc:invoke "NSScrollView" "alloc") "initWithFrame:" table-frame))
         (table (objc:invoke (objc:invoke "NSTableView" "alloc") "initWithFrame:" table-frame)))
    (objc:invoke panel "setReleasedWhenClosed:" nil)
    (objc:invoke panel "setTitle:" "Views")
    (objc:invoke content "addSubview:"
                 (make-inspector-label "Every view, and whether it applies to this object"
                                       margin (- height margin 16d0) (- width (* 2 margin))
                                       :bold t))
    ;; The table.
    (loop for (title column-width) in '(("View" 110d0) ("Shows" 190d0) ("From" 150d0)
                                        ("Priority" 54d0) ("For this object" 210d0))
          for index from 0
          do (let ((column (objc:invoke (objc:invoke "NSTableColumn" "alloc")
                                        "initWithIdentifier:" (format nil "~d" index))))
               (objc:invoke column "setWidth:" column-width)
               (objc:invoke (objc:invoke column "headerCell") "setStringValue:" title)
               (objc:invoke (objc:invoke column "dataCell") "setFont:" (inspector-font))
               (objc:invoke (objc:invoke column "dataCell") "setLineBreakMode:" 4)
               (objc:invoke column "setEditable:" nil)
               (objc:invoke table "addTableColumn:" column)
               (objc:release column)))
    (objc:invoke table "setRowHeight:" *inspector-row-height*)
    (objc:invoke table "setUsesAlternatingRowBackgroundColors:" t)
    (objc:invoke table "setAllowsMultipleSelection:" nil)
    (objc:invoke table "setAllowsColumnReordering:" nil)
    (objc:invoke table "setColumnAutoresizingStyle:" 4)
    (objc:invoke table "setDataSource:" target)
    (objc:invoke table "setDelegate:" target)
    (objc:invoke scroll "setHasVerticalScroller:" t)
    (objc:invoke scroll "setAutohidesScrollers:" t)
    (objc:invoke scroll "setBorderType:" 2)       ; a bezel
    (objc:invoke scroll "setDocumentView:" table)
    (objc:invoke table "sizeLastColumnToFit")
    (objc:invoke content "addSubview:" scroll)
    (objc:release table)
    (objc:release scroll)
    ;; What the selected view shows, and why it does not apply if it does not.
    (let ((about (make-inspector-label "" margin about-y (- width (* 2 margin))
                                       :secondary t :height 32d0)))
      (objc:invoke (objc:invoke about "cell") "setLineBreakMode:" 0) ; wrap by word
      (objc:invoke (objc:invoke about "cell") "setWraps:" t)
      (objc:invoke content "addSubview:" about)
      (setf (inspector-part inspector :sheet-about) about))
    ;; How to add one.
    (objc:invoke content "addSubview:"
                 (make-inspector-label "To add a view of your own, evaluate something like this:"
                                       margin (+ snippet-y snippet-height 2d0)
                                       (- width (* 2 margin)) :bold t))
    (let ((snippet (make-inspector-label (views-sheet-snippet inspector) margin snippet-y
                                         (- width (* 2 margin)) :height snippet-height)))
      (objc:invoke snippet "setFont:" (inspector-mono-font))
      (objc:invoke snippet "setSelectable:" t)
      (objc:invoke (objc:invoke snippet "cell") "setLineBreakMode:" 2) ; clip
      (objc:invoke content "addSubview:" snippet)
      (setf (inspector-part inspector :sheet-snippet) snippet))
    ;; The buttons.
    (flet ((button (title selector x button-width key)
             (let ((button (objc:invoke "NSButton" "buttonWithTitle:target:action:"
                                        title target (objc:coerce-to-selector selector))))
               (objc:invoke button "setFrame:" (vector x buttons-y button-width 30d0))
               (when key (objc:invoke button "setKeyEquivalent:" key))
               (objc:invoke content "addSubview:" button)
               button)))
      (setf (inspector-part inspector :sheet-left)
            (button "Show in Left Pane" "inspectorSheetLeft:" margin 150d0 nil)
            (inspector-part inspector :sheet-right)
            (button "Show in Right Pane" "inspectorSheetRight:" (+ margin 154d0) 156d0 nil)
            (inspector-part inspector :sheet-done)
            (button "Done" "inspectorSheetDone:" (- width margin 90d0) 90d0
                    (string #\Return))))
    (setf (inspector-part inspector :sheet) panel
          (inspector-part inspector :sheet-table) table)
    panel))

(defun views-sheet-open-p (inspector)
  (live-pointer-p (inspector-part inspector :sheet)))

(defun refresh-views-sheet (inspector)
  "Show the model's views in the sheet, if it is up."
  (when (views-sheet-open-p inspector)
    (setf (inspector-part inspector :sheet-rows) (views-sheet-rows inspector))
    (objc:invoke (inspector-part inspector :sheet-table) "reloadData")
    (objc:invoke (inspector-part inspector :sheet-snippet) "setStringValue:"
                 (views-sheet-snippet inspector))
    (show-views-sheet-selection inspector)
    t))

(defun show-views-sheet (inspector)
  (hide-views-sheet inspector)
  (let ((panel (build-views-sheet inspector))
        (window (inspector-part inspector :window)))
    (refresh-views-sheet inspector)
    ;; No completion handler: HIDE-VIEWS-SHEET ends it, on every path.
    (objc:invoke window "beginSheet:completionHandler:" panel (cffi:null-pointer))
    panel))

(defun hide-views-sheet (inspector)
  "Take the sheet down.  Idempotent."
  (let ((panel (inspector-part inspector :sheet)))
    (when (live-pointer-p panel)
      (let ((parent (objc:invoke panel "sheetParent")))
        (if (cffi:null-pointer-p parent)
            (objc:invoke panel "orderOut:" nil)
            (objc:invoke parent "endSheet:" panel)))
      (objc:invoke (inspector-part inspector :sheet-table) "setDataSource:" (cffi:null-pointer))
      (objc:invoke (inspector-part inspector :sheet-table) "setDelegate:" (cffi:null-pointer))
      ;; Not released outright: the window is still sliding it away.
      (objc:autorelease panel))
    (dolist (key '(:sheet :sheet-table :sheet-about :sheet-snippet :sheet-left :sheet-right
                   :sheet-done))
      (setf (inspector-part inspector key) nil))
    t))

(defun views-sheet-choose (inspector pane)
  "Put the sheet's selected view in PANE, and take the sheet down."
  (let ((row (views-sheet-selected inspector)))
    (when (and row (getf row :applies))
      (hide-views-sheet inspector)
      (inspector-select-view inspector pane (getf row :name)))))

(define-inspector-method ("inspectorAllViews:" :void) ((sender objc:objc-object-pointer))
  (show-views-sheet inspector))

(define-inspector-method ("inspectorSheetDone:" :void) ((sender objc:objc-object-pointer))
  (hide-views-sheet inspector))

(define-inspector-method ("inspectorSheetLeft:" :void) ((sender objc:objc-object-pointer))
  (views-sheet-choose inspector 0))

(define-inspector-method ("inspectorSheetRight:" :void) ((sender objc:objc-object-pointer))
  (views-sheet-choose inspector 1))

;;; The window -----------------------------------------------------------------------

(defun inspector-window-frame ()
  "Where a new inspector's window goes: where the last one was, a little down
and to the right for each one already open."
  (let ((remembered (remembered :inspector))
        (open (count-if (lambda (inspector) (inspector-part inspector :window)) *inspectors*)))
    (if (and (sound-frame-p remembered) (frame-on-a-screen-p remembered))
        (list (+ (first remembered) (* 24 open)) (- (second remembered) (* 24 open))
              (third remembered) (fourth remembered))
        nil)))

(defun build-inspector-window (inspector)
  (let* ((width *inspector-width*) (height *inspector-height*)
         (bar *inspector-bar-height*)
         (status 22d0)
         (panel-width *inspector-panel-width*)
         (controller (make-instance 'inspector-window-controller))
         (target (objc:objc-object-pointer controller))
         (window (objc:invoke (objc:invoke "NSWindow" "alloc")
                              "initWithContentRect:styleMask:backing:defer:"
                              (vector 0d0 0d0 width height) +ns-window-style-mask+
                              +ns-backing-store-buffered+ nil))
         (content (objc:invoke window "contentView"))
         (path-bar (make-plain-view (vector 0d0 (- height bar) width bar)
                                    (logior +ns-view-width-sizable+ +ns-view-min-y-margin+)))
         (message (make-inspector-label "" 8d0 3d0 (- width 16d0) :secondary t))
         (split (objc:invoke (objc:invoke "NSSplitView" "alloc") "initWithFrame:"
                             (vector 0d0 status (- width panel-width) (- height bar status))))
         (panel (make-plain-view (vector (- width panel-width) status panel-width
                                         (- height bar status))
                                 (logior +ns-view-min-x-margin+ +ns-view-height-sizable+)))
         (pane-width (/ (- width panel-width) 2))
         (panes '()))
    (setf (controller-inspector controller) inspector)
    (objc:invoke window "setReleasedWhenClosed:" nil)
    (objc:invoke window "setMinSize:" (vector 640d0 360d0))
    (objc:invoke message "setAutoresizingMask:" +ns-view-width-sizable+)
    (objc:invoke split "setVertical:" t)
    (objc:invoke split "setDividerStyle:" 2)      ; thin
    (objc:invoke split "setAutoresizingMask:"
                 (logior +ns-view-width-sizable+ +ns-view-height-sizable+))
    (dotimes (index 2)
      (multiple-value-bind (pane parts)
          (build-inspector-pane inspector index
                                (vector 0d0 0d0 pane-width (- height bar status)))
        (objc:invoke split "addSubview:" pane)
        (objc:release pane)
        (push parts panes)))
    (objc:invoke content "addSubview:" path-bar)
    (objc:invoke content "addSubview:" split)
    (objc:invoke content "addSubview:" panel)
    (objc:invoke content "addSubview:" message)
    (objc:release path-bar)
    (objc:release split)
    (objc:release panel)
    (objc:invoke window "setDelegate:" target)
    (let ((frame (inspector-window-frame)))
      (if frame
          (set-window-frame window frame)
          (objc:invoke window "center")))
    (setf (inspector-retained inspector)
          (list :window window :controller controller :path-bar path-bar :split split
                :panel panel :message message :panes (nreverse panes) :selection nil))
    window))

(defun refresh-inspector (inspector)
  "Show INSPECTOR's model in its window.  Nothing to do when it has none."
  (let ((window (inspector-part inspector :window))
        (model (inspector-model inspector)))
    (when (and (live-pointer-p window) model)
      (objc:invoke window "setTitle:" (format nil "Inspector — ~a" (model-title model)))
      (refresh-inspector-path inspector)
      (objc:invoke (inspector-part inspector :message) "setStringValue:"
                   (or (model-message model) ""))
      (dotimes (index 2)
        (refresh-inspector-pane inspector index))
      (refresh-inspector-panel inspector)
      (refresh-views-sheet inspector)
      t)))

(defun show-inspector (inspector)
  "Put INSPECTOR's window up, made if need be, showing its model."
  (unless (live-pointer-p (inspector-part inspector :window))
    (build-inspector-window inspector))
  (refresh-inspector inspector)
  (objc:invoke (inspector-part inspector :window) "makeKeyAndOrderFront:" nil)
  t)

(defun hide-inspectors ()
  "Close every inspector's window: they go with the last listener."
  (dolist (inspector (copy-list *inspectors*))
    (let ((window (inspector-part inspector :window)))
      (when (and (live-pointer-p window) (objc:invoke-bool window "isVisible"))
        (objc:invoke window "close"))))
  t)
