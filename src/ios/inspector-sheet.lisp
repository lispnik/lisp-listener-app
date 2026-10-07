;;;; src/ios/inspector-sheet.lisp -- the inspector, as a sheet.
;;;;
;;;; iOS's half of src/inspector.lisp, as src/macos/inspector-window.lisp is the
;;;; Mac's.  A phone has room for one thing at a time, so there is ONE pane --
;;;; the inspector's first -- and one inspector on screen: a second (inspect x)
;;;; takes the sheet over.  From the top:
;;;;
;;;;   - Back, the path walked so far, Views -- a list of every view there is,
;;;;     with why each that does not apply does not -- and Done;
;;;;   - the views that apply, as a segmented control;
;;;;   - the chosen view's options, and the controls contributed for the object;
;;;;   - what the view's scene comes to: a drawing, a table, some text, or a
;;;;     view of UIKit's own;
;;;;   - and at the foot the row that is selected, a field with its value, and
;;;;     what can be done with it: Open, Set, Insert, Remove, Add.
;;;;
;;;; NOTHING HERE EVALUATES, as on the Mac: what is shown is the MODEL the
;;;; worker made, and a tap is a request whose answer is another model.
;;;;
;;;; Every control's target is the sheet's one controller, told apart by tag.
;;;; UIKIT:ON-TAP would do, but it keeps its target for the life of the image,
;;;; and these controls are made again whenever the view changes.
;;;;
;;;; Thread 1, all of it.

(in-package #:lisp-listener)

(defparameter *inspector-sheet-margin* 14d0)
(defparameter *inspector-sheet-row-height* 46d0)
(defparameter *inspector-sheet-header-height* 28d0)
(defparameter *inspector-sheet-font-size* 14d0)
(defparameter *inspector-present-limit* 12
  "How many times, a quarter of a second apart, presenting the sheet is tried.")

(defvar *inspector-shown* nil
  "The inspector whose sheet is up, or NIL.")

(defun inspector-capabilities ()
  "A table, some text, a drawing, and a view of UIKit's own."
  '(:table :text :drawing :native :uikit))

(defun inspector-part (inspector key)
  (getf (inspector-retained inspector) key))

(defun (setf inspector-part) (value inspector key)
  (setf (getf (inspector-retained inspector) key) value))

(defun sheet-pane-model (inspector)
  (let ((model (inspector-model inspector)))
    (and model (first (model-panes model)))))

;;; The controller --------------------------------------------------------------------

(objc:define-objc-class inspector-sheet-controller ()
  ((inspector :initform nil :accessor sheet-controller-inspector))
  (:objc-class-name "LispListenerInspectorSheetController"))

(defmacro define-sheet-method ((selector result-type &key on-error) (&rest argspecs)
                               &body body)
  "A method of the sheet's controller.  INSPECTOR is bound; nothing may unwind
into UIKit."
  `(objc:define-objc-method (,selector ,result-type)
       ((self inspector-sheet-controller) ,@argspecs)
     (declare (ignorable ,@(mapcar #'first argspecs)))
     (handler-case
         (let ((inspector (sheet-controller-inspector self)))
           (declare (ignorable inspector))
           ,@body)
       (error (condition)
         (note "inspector ~a: ~a" ,selector condition)
         ,on-error))))

;;; The drawing ----------------------------------------------------------------------

(objc:define-objc-class inspector-drawing-view ()
  ((scene :initform nil :accessor drawing-view-scene)
   ;; Whether a finger is on it, and what was last said about where it is:
   ;; (TEXT X Y), in the canvas's units.
   (inside :initform nil :accessor drawing-view-inside)
   (readout :initform nil :accessor drawing-view-readout)
   ;; Where the finger landed, in the view's own points: (X . Y), or NIL.
   (press :initform nil :accessor drawing-view-press))
  (:objc-class-name "LispListenerInspectorDrawing")
  (:objc-superclass-name "UIView"))

(defparameter *drawing-tap-slop* 8d0
  "How far, in points, a finger may move between landing and lifting and
still be a tap rather than a drag.")

(objc:define-objc-method ("drawRect:" :void)
    ((self inspector-drawing-view pointer) (dirty cocoa:ns-rect))
  (declare (ignorable dirty))
  (handler-case
      (let ((bounds (objc:invoke pointer "bounds"))
            (scene (drawing-view-scene self)))
        (paint-shapes (append (and scene (drawing-scene-ops scene))
                              (let ((readout (drawing-view-readout self)))
                                (and readout (apply #'readout-shapes readout))))
                      (or (and scene (drawing-scene-background scene))
                          *canvas-default-background*)
                      (aref bounds 2) (aref bounds 3)))
    (error (condition) (note "inspector drawRect: ~a" condition))))

(defun inspector-drawing-touch (inspector phase x y)
  "A finger on the drawing at (X, Y) in the view's own coordinates: PHASE is
:DOWN as it lands, :MOVE while it is down, and :UP when it lifts -- or :CANCEL,
when UIKit takes it away.  Down, the view's readout is asked what is under it;
lifted, what was said is taken away; and lifted where it landed, a tap, the
drawing's OPEN is asked what is there to walk into."
  (let* ((object (inspector-part inspector :drawing-object))
         (view (inspector-part inspector :drawing))
         (bounds (objc:invoke view "bounds")))
    (cond ((member phase '(:up :cancel))
           (let ((press (shiftf (drawing-view-press object) nil))
                 (scene (drawing-view-scene object)))
             (setf (drawing-view-inside object) nil
                   (drawing-view-readout object) nil)
             (objc:invoke view "setNeedsDisplay")
             (when (and (eq phase :up) press scene (drawing-scene-open scene)
                        (<= (abs (- x (car press))) *drawing-tap-slop*)
                        (<= (abs (- y (cdr press))) *drawing-tap-slop*))
               (let ((point (canvas-point-from-view x y (aref bounds 2) (aref bounds 3))))
                 (inspector-open-at-point inspector 0 (car point) (cdr point))))))
          (t
           (when (eq phase :down)
             (setf (drawing-view-press object) (cons x y)))
           (setf (drawing-view-inside object) t)
           (when (and (drawing-view-scene object)
                      (drawing-scene-readout (drawing-view-scene object)))
             (let ((point (canvas-point-from-view x y (aref bounds 2) (aref bounds 3))))
               (inspector-request-readout inspector 0 (car point) (cdr point))))))
    phase))

(defun show-inspector-readout (inspector pane text x y)
  "Say TEXT at (X, Y) on the drawing -- if the finger is still on it."
  (declare (ignore pane))
  (let ((object (inspector-part inspector :drawing-object)))
    (when (and object (drawing-view-inside object))
      (setf (drawing-view-readout object) (and text (list text x y)))
      (objc:invoke (inspector-part inspector :drawing) "setNeedsDisplay")
      t)))

;;; UIGestureRecognizerState is 1 as it begins, 2 while it changes and 3 as it
;;; ends; after that it was cancelled, or failed.
(define-sheet-method ("sheetTouch:" :void) ((recognizer objc:objc-object-pointer))
  (let ((point (objc:invoke recognizer "locationInView:" (inspector-part inspector :drawing))))
    (inspector-drawing-touch inspector
                             (case (objc:invoke recognizer "state")
                               (1 :down) (2 :move) (3 :up) (t :cancel))
                             (aref point 0) (aref point 1))))

;;; The table ------------------------------------------------------------------------

(defun sheet-table-model (inspector)
  (let ((pane (sheet-pane-model inspector)))
    (and pane (pane-model-table pane))))

(defun sheet-row (inspector index)
  "Row INDEX of the table, or NIL -- and then it is asked for, once for each
stretch of the table that is scrolled to."
  (let ((model (sheet-table-model inspector)))
    (when model
      (or (table-row model index)
          (let ((asked (or (inspector-part inspector :rows-asked) -1)))
            (when (> index asked)
              (setf (inspector-part inspector :rows-asked) (+ index *inspector-row-chunk*))
              (inspector-need-rows inspector 0 index))
            nil)))))

(define-sheet-method ("tableView:numberOfRowsInSection:" (:signed :long-long) :on-error 0)
    ((table objc:objc-object-pointer) (section (:signed :long-long)))
  (if (views-list-table-p table)
      (length (inspector-part inspector :list-rows))
      (let ((model (sheet-table-model inspector)))
        (if model (table-model-count model) 0))))

(defun make-inspector-cell (row)
  "One row, AUTORELEASED.  A heading is bold and cannot be chosen.  Any other
row is its value -- every cell after the first -- over its label, small and
grey: the Mac's columns, stacked for a phone's width."
  (cond
    ((null row)
     (let ((cell (make-blank-cell)))
       (objc:invoke (objc:invoke cell "textLabel") "setText:" "…")
       cell))
    ((row-header-p row)
     (let* ((cell (objc:invoke (objc:invoke "UITableViewCell" "alloc")
                               "initWithStyle:reuseIdentifier:" 0 "heading"))
            (label (objc:invoke cell "textLabel")))
       (objc:invoke label "setText:" (or (first (row-cells row)) ""))
       (objc:invoke label "setFont:" (uikit:bold-font (- *inspector-sheet-font-size* 1)))
       (objc:invoke label "setTextColor:" (objc:invoke "UIColor" "secondaryLabelColor"))
       (objc:invoke cell "setSelectionStyle:" 0)
       (objc:autorelease cell)))
    (t
     (let* ((cell (objc:invoke (objc:invoke "UITableViewCell" "alloc")
                               "initWithStyle:reuseIdentifier:" 3 "row")) ; subtitle
            (label (objc:invoke cell "textLabel"))
            (detail (objc:invoke cell "detailTextLabel"))
            (cells (row-cells row)))
       (objc:invoke label "setText:" (if (rest cells)
                                         (format nil "~{~a~^  ~}" (rest cells))
                                         (or (first cells) "")))
       (objc:invoke label "setFont:" (uikit:mono-font *inspector-sheet-font-size*))
       (objc:invoke label "setLineBreakMode:" 4) ; truncating tail
       (objc:invoke detail "setText:" (if (rest cells) (first cells) ""))
       (objc:invoke detail "setFont:" (uikit:mono-font (- *inspector-sheet-font-size* 3)))
       (objc:invoke detail "setTextColor:" (objc:invoke "UIColor" "secondaryLabelColor"))
       (objc:autorelease cell)))))

;;; Never nil: see MAKE-BLANK-CELL.
(define-sheet-method ("tableView:cellForRowAtIndexPath:" objc:objc-object-pointer
                      :on-error (make-blank-cell))
    ((table objc:objc-object-pointer) (index-path objc:objc-object-pointer))
  (if (views-list-table-p table)
      (make-views-list-cell inspector (nth (objc:invoke index-path "row")
                                           (inspector-part inspector :list-rows)))
      (make-inspector-cell (sheet-row inspector (objc:invoke index-path "row")))))

(define-sheet-method ("tableView:heightForRowAtIndexPath:" :double
                      :on-error *inspector-sheet-row-height*)
    ((table objc:objc-object-pointer) (index-path objc:objc-object-pointer))
  (let* ((model (sheet-table-model inspector))
         (row (and model (table-row model (objc:invoke index-path "row")))))
    (cond ((views-list-table-p table) 54d0)
          ((and row (row-header-p row)) *inspector-sheet-header-height*)
          ;; A row of one cell has no label under it.
          ((and row (null (rest (row-cells row)))) 34d0)
          (t *inspector-sheet-row-height*))))

(define-sheet-method ("tableView:willSelectRowAtIndexPath:" objc:objc-object-pointer
                      :on-error (cffi:null-pointer))
    ((table objc:objc-object-pointer) (index-path objc:objc-object-pointer))
  (let* ((model (sheet-table-model inspector))
         (row (and model (table-row model (objc:invoke index-path "row")))))
    (cond ((views-list-table-p table)
           ;; A view that does not apply is there to be read, not chosen.
           (if (getf (nth (objc:invoke index-path "row")
                          (inspector-part inspector :list-rows))
                     :applies)
               index-path
               (cffi:null-pointer)))
          ((and row (not (row-header-p row))) index-path)
          (t (cffi:null-pointer)))))

(define-sheet-method ("tableView:didSelectRowAtIndexPath:" :void)
    ((table objc:objc-object-pointer) (index-path objc:objc-object-pointer))
  (cond ((views-list-table-p table)
         (let ((row (nth (objc:invoke index-path "row")
                         (inspector-part inspector :list-rows))))
           (when (and row (getf row :applies))
             (hide-views-list inspector)
             (inspector-select-view inspector 0 (getf row :name)))))
        (t
         (setf (inspector-part inspector :selection) (objc:invoke index-path "row"))
         (show-inspector-selection inspector))))

;;; Every view there is ---------------------------------------------------------------
;;;
;;; A second sheet, over the inspector's: the views that apply, and under them
;;; the ones that do not, each saying why -- the Mac's All Views sheet, for a
;;; phone's width.  A tap on one that applies shows it.  Its table shares the
;;; inspector's controller and is told apart by its tag.

(defconstant +views-list-tag+ 1)

(defun views-list-table-p (table)
  (= +views-list-tag+ (objc:invoke table "tag")))

(defun make-views-list-cell (inspector row)
  "One view, AUTORELEASED: its title over what it is matched by and who
contributed it -- or, where it does not apply, why not, in grey."
  (if (null row)
      (make-blank-cell)
      (let* ((cell (objc:invoke (objc:invoke "UITableViewCell" "alloc")
                                "initWithStyle:reuseIdentifier:" 3 "view"))
             (label (objc:invoke cell "textLabel"))
             (detail (objc:invoke cell "detailTextLabel"))
             (pane (sheet-pane-model inspector))
             (secondary (objc:invoke "UIColor" "secondaryLabelColor")))
        (objc:invoke label "setText:" (getf row :title))
        (objc:invoke label "setFont:" (uikit:font (+ *inspector-sheet-font-size* 2)))
        (objc:invoke detail "setFont:" (uikit:font (- *inspector-sheet-font-size* 2)))
        (objc:invoke detail "setTextColor:" secondary)
        (cond ((getf row :applies)
               (objc:invoke detail "setText:"
                            (format nil "~a  ·  ~a" (getf row :matches) (getf row :contributor)))
               ;; UITableViewCellAccessoryCheckmark, on the one that is showing.
               (when (and pane (eq (getf row :name) (pane-model-view-name pane)))
                 (objc:invoke cell "setAccessoryType:" 3)))
              (t
               (objc:invoke label "setTextColor:" secondary)
               (objc:invoke detail "setText:" (or (getf row :reason) "Does not apply."))
               (objc:invoke cell "setSelectionStyle:" 0)))
        (objc:autorelease cell))))

(defun views-list-up-p (&optional (inspector *inspector-shown*))
  (let ((list (and inspector (inspector-part inspector :list-controller))))
    (and (live-pointer-p list)
         (live-pointer-p (objc:invoke list "presentingViewController")))))

(defun hide-views-list (&optional (inspector *inspector-shown*))
  "Take the list down and let go of it.  Idempotent."
  ;; Its table KEEPS its data source.  A sheet on its way out is still a table
  ;; on screen, and on an iPad the focus engine walks it then: with nobody to
  ;; ask, a row it had been promised has no cell, which is an assertion in
  ;; UITableView and the end of the app.  The controller outlives the sheet
  ;; and answers a blank cell for a row it no longer has.
  (let ((list (and inspector (inspector-part inspector :list-controller))))
    (when (live-pointer-p list)
      (let ((listener (or (inspector-listener inspector) (current-listener))))
        (when listener
          (dismiss-sheet-when-settled (listener-view listener) list nil)))
      (objc:autorelease list))
    (when inspector
      (setf (inspector-part inspector :list-controller) nil
            (inspector-part inspector :list-table) nil))
    t))

(defun show-views-list (&optional (inspector *inspector-shown*))
  "Present the list of every view, over INSPECTOR's sheet."
  (hide-views-list inspector)
  (let* ((model (inspector-model inspector))
         (target (sheet-target inspector))
         (controller (objc:invoke (objc:invoke "UIViewController" "alloc") "init"))
         (root (objc:invoke controller "view"))
         (header (sheet-stack 0 10d0))
         (title (sheet-label "Views" :size 17d0 :bold t))
         (close (uikit:system-button "Close"))
         (table (uikit:new "UITableView"))
         (hint (sheet-label (format nil "To add one of your own:~%(inspector:define-view (my-view :title \"Mine\" ~a)~%    (object)~%  (inspector:text \"~~a\" object))"
                                    (model-match model))
                            :size 11d0 :mono t :secondary t))
         (margin *inspector-sheet-margin*))
    (setf (inspector-part inspector :list-rows) (model-views-sorted model)
          (inspector-part inspector :list-controller) controller
          (inspector-part inspector :list-table) table)
    (objc:invoke root "setBackgroundColor:" (objc:invoke "UIColor" "systemBackgroundColor"))
    (objc:invoke title "setContentHuggingPriority:forAxis:" 1.0 0)
    (sheet-action close inspector "sheetCloseList:")
    (objc:invoke header "addArrangedSubview:" title)
    (objc:invoke header "addArrangedSubview:" close)
    (objc:invoke table "setTag:" +views-list-tag+)
    (objc:invoke table "setDataSource:" target)
    (objc:invoke table "setDelegate:" target)
    (objc:invoke hint "setNumberOfLines:" 0)
    (dolist (view (list header table hint))
      (objc:invoke root "addSubview:" view))
    (let ((safe (objc:invoke root "safeAreaLayoutGuide")))
      (uikit:pin header "topAnchor" root "topAnchor" (+ margin 6))
      (uikit:pin header "leadingAnchor" safe "leadingAnchor" margin)
      (uikit:pin header "trailingAnchor" safe "trailingAnchor" (- margin))
      (uikit:pin table "topAnchor" header "bottomAnchor" 8)
      (uikit:pin table "leadingAnchor" root "leadingAnchor")
      (uikit:pin table "trailingAnchor" root "trailingAnchor")
      (uikit:pin table "bottomAnchor" hint "topAnchor" -8)
      (uikit:pin hint "leadingAnchor" safe "leadingAnchor" margin)
      (uikit:pin hint "trailingAnchor" safe "trailingAnchor" (- margin))
      (uikit:pin hint "bottomAnchor" safe "bottomAnchor" (- margin)))
    (handler-case (objc:invoke (inspector-part inspector :controller)
                               "presentViewController:animated:completion:"
                               controller nil nil)
      (error (condition) (note "inspector: ~a" condition)))
    (views-list-up-p inspector)))

(define-sheet-method ("sheetAllViews:" :void) ((sender objc:objc-object-pointer))
  (show-views-list inspector))

(define-sheet-method ("sheetCloseList:" :void) ((sender objc:objc-object-pointer))
  (hide-views-list inspector))

;;; The row selected, and what can be done with it -----------------------------------

(defun sheet-selected-row (inspector)
  (let ((index (inspector-part inspector :selection)))
    (and index (inspector-pane-row inspector 0 index))))

(defun sheet-field-text (inspector)
  (or (ignore-errors
       (objc:ns-string-to-string (objc:invoke (inspector-part inspector :field) "text")))
      ""))

(defun show-inspector-selection (inspector)
  "Put the selected row's value in the field, and offer what the row allows."
  (let* ((row (sheet-selected-row inspector))
         (cell (row-cell row))
         (model (inspector-model inspector))
         (caption (inspector-part inspector :caption))
         (field (inspector-part inspector :field)))
    (when (live-pointer-p field)
      (cond (cell
             (let ((place (nth cell (row-places row))))
               (objc:invoke caption "setText:"
                            (format nil "~a~:[ (read-only)~;~]"
                                    (clip-string (or (inspector:place-label place)
                                                     (first (row-cells row))
                                                     "")
                                                 40)
                                    (row-editable-p row))))
             (objc:invoke field "setText:" (or (nth cell (row-cells row)) "")))
            (t
             (objc:invoke caption "setText:"
                          (if (and model (model-addition model))
                              (if (eq (model-addition model) :key-and-value)
                                  "No row selected.  To add: a key, then a value."
                                  "No row selected.  To add: a value.")
                              "No row selected"))))
      (flet ((enable (key enabled)
               (objc:invoke (inspector-part inspector key) "setEnabled:" (and enabled t))))
        (enable :open cell)
        (enable :set (and cell (row-editable-p row)))
        (enable :insert (and cell (row-insertable-p row)))
        (enable :remove (and cell (row-removable-p row)))
        (enable :add (and model (model-addition model))))
      t)))

(define-sheet-method ("sheetOpen:" :void) ((sender objc:objc-object-pointer))
  (let ((index (inspector-part inspector :selection)))
    (when index
      (inspector-open-row inspector 0 index))))

(define-sheet-method ("sheetSet:" :void) ((sender objc:objc-object-pointer))
  (let ((index (inspector-part inspector :selection)))
    (when index
      (objc:invoke (inspector-part inspector :field) "resignFirstResponder")
      (inspector-edit-row inspector 0 index (sheet-field-text inspector)))))

(define-sheet-method ("sheetInsert:" :void) ((sender objc:objc-object-pointer))
  (let ((index (inspector-part inspector :selection)))
    (when index
      (objc:invoke (inspector-part inspector :field) "resignFirstResponder")
      (inspector-insert-row inspector 0 index (sheet-field-text inspector)))))

(define-sheet-method ("sheetRemove:" :void) ((sender objc:objc-object-pointer))
  (let ((index (inspector-part inspector :selection)))
    (when index
      (inspector-remove-row inspector 0 index))))

(define-sheet-method ("sheetAdd:" :void) ((sender objc:objc-object-pointer))
  (objc:invoke (inspector-part inspector :field) "resignFirstResponder")
  (inspector-add-line inspector (sheet-field-text inspector)))

;;; Return in the field at the foot sets the selected row; in a contributed
;;; control's field -- its tag is the control's position -- it sets that.
(define-sheet-method ("textFieldShouldReturn:" objc:objc-bool)
    ((field objc:objc-object-pointer))
  (let ((tag (objc:invoke field "tag"))
        (text (or (ignore-errors (objc:ns-string-to-string (objc:invoke field "text"))) "")))
    (objc:invoke field "resignFirstResponder")
    (cond ((>= tag 0) (inspector-set-control inspector tag text))
          ((inspector-part inspector :selection)
           (inspector-edit-row inspector 0 (inspector-part inspector :selection) text)))
    nil))

;;; The view, its options, and the contributed controls ------------------------------

(define-sheet-method ("sheetView:" :void) ((sender objc:objc-object-pointer))
  (let* ((pane (sheet-pane-model inspector))
         (choice (and pane (nth (objc:invoke sender "selectedSegmentIndex")
                                (pane-model-choices pane)))))
    (when choice
      (inspector-select-view inspector 0 (car choice)))))

(define-sheet-method ("sheetOption:" :void) ((sender objc:objc-object-pointer))
  (let* ((pane (sheet-pane-model inspector))
         (option (and pane (nth (objc:invoke sender "tag") (pane-model-options pane)))))
    (when option
      (inspector-set-option
       inspector 0 (option-model-keyword option)
       (ecase (option-model-kind option)
         (:boolean (objc:invoke-bool sender "isOn"))
         ((:integer :number) (objc:invoke sender "value"))
         (:choice (nth (objc:invoke sender "selectedSegmentIndex")
                       (option-model-choices option))))))))

(define-sheet-method ("sheetControl:" :void) ((sender objc:objc-object-pointer))
  (let* ((index (objc:invoke sender "tag"))
         (control (nth index (model-controls (inspector-model inspector)))))
    (when control
      (inspector-set-control
       inspector index
       (ecase (control-model-kind control)
         (:slider (objc:invoke sender "value"))
         (:toggle (objc:invoke-bool sender "isOn"))
         (:button nil))))))

(define-sheet-method ("sheetBack:" :void) ((sender objc:objc-object-pointer))
  (let ((depth (length (model-path (inspector-model inspector)))))
    (when (> depth 1)
      (inspector-go-to inspector (- depth 2)))))

(define-sheet-method ("sheetDone:" :void) ((sender objc:objc-object-pointer))
  (hide-inspector inspector))

;;; UIKit sends this when the person drags the sheet away, and not when the
;;; program dismisses it.
(define-sheet-method ("presentationControllerDidDismiss:" :void)
    ((presentation objc:objc-object-pointer))
  (forget-inspector-sheet inspector))

(define-sheet-method ("sheetPresent" :void) ()
  (present-inspector-sheet inspector))

;;; Small pieces ---------------------------------------------------------------------

(defun sheet-target (inspector)
  (objc:objc-object-pointer (inspector-part inspector :controller-object)))

(defun sheet-action (control inspector selector &optional (events 64))
  "Send SELECTOR to the sheet's controller when CONTROL fires: on a tap (64),
or when its value changes (4096)."
  (objc:invoke control "addTarget:action:forControlEvents:"
               (sheet-target inspector) selector events)
  control)

(defun sheet-stack (axis spacing)
  (let ((stack (uikit:new "UIStackView")))
    (objc:invoke stack "setAxis:" axis)         ; 0 across, 1 down
    (objc:invoke stack "setSpacing:" spacing)
    stack))

(defun sheet-label (text &key (size *inspector-sheet-font-size*) bold secondary mono)
  (let ((label (uikit:new "UILabel")))
    (objc:invoke label "setText:" text)
    (objc:invoke label "setFont:" (cond (bold (uikit:bold-font size))
                                        (mono (uikit:mono-font size))
                                        (t (uikit:font size))))
    (when secondary
      (objc:invoke label "setTextColor:" (objc:invoke "UIColor" "secondaryLabelColor")))
    label))

(defun remove-arranged-subviews (stack)
  (let ((views (objc:invoke (objc:invoke stack "arrangedSubviews") "copy")))
    (dotimes (index (objc:invoke views "count"))
      (objc:invoke (objc:invoke views "objectAtIndex:" index) "removeFromSuperview"))
    (objc:release views)))

(defun labelled-row (title control)
  "TITLE on the left and CONTROL filling the rest."
  (let ((row (sheet-stack 0 10d0))
        (label (sheet-label title :secondary t)))
    (objc:invoke row "setAlignment:" 3)         ; centred
    ;; The label keeps its own width; the control stretches.
    (objc:invoke label "setContentHuggingPriority:forAxis:" 751.0 0)
    (objc:invoke row "addArrangedSubview:" label)
    (objc:invoke row "addArrangedSubview:" control)
    row))

(defun make-sheet-slider (inspector selector tag low high)
  (let ((slider (uikit:new "UISlider")))
    (objc:invoke slider "setMinimumValue:" (float low 1f0))
    (objc:invoke slider "setMaximumValue:" (float high 1f0))
    ;; Told when the finger lifts, not all the way along: each telling is a
    ;; scene computed again.
    (objc:invoke slider "setContinuous:" nil)
    (objc:invoke slider "setTag:" tag)
    (sheet-action slider inspector selector 4096)))

(defun make-sheet-switch (inspector selector tag)
  (let ((switch (uikit:new "UISwitch")))
    (objc:invoke switch "setTag:" tag)
    (sheet-action switch inspector selector 4096)))

(defun make-sheet-segments (inspector selector tag titles)
  (let ((segments (uikit:new "UISegmentedControl")))
    (loop for title in titles
          for index from 0
          do (objc:invoke segments "insertSegmentWithTitle:atIndex:animated:" title index nil))
    (objc:invoke segments "setApportionsSegmentWidthsByContent:" t)
    (objc:invoke segments "setTag:" tag)
    (sheet-action segments inspector selector 4096)))

;;; Options --------------------------------------------------------------------------

(defun build-sheet-options (inspector pane)
  "A row for each of the view's options.  Answers the controls, in order."
  (let ((stack (inspector-part inspector :options)))
    (remove-arranged-subviews stack)
    (loop for option in (pane-model-options pane)
          for tag from 0
          collect (let ((control
                          (ecase (option-model-kind option)
                            (:boolean (make-sheet-switch inspector "sheetOption:" tag))
                            ((:integer :number)
                             (make-sheet-slider inspector "sheetOption:" tag
                                                (or (option-model-min option) 0)
                                                (or (option-model-max option) 100)))
                            (:choice
                             (make-sheet-segments
                              inspector "sheetOption:" tag
                              (mapcar (lambda (choice)
                                        (string-downcase (princ-to-string choice)))
                                      (option-model-choices option)))))))
                    (objc:invoke stack "addArrangedSubview:"
                                 (labelled-row (option-model-label option) control))
                    control))))

(defun set-sheet-option (control option)
  (ecase (option-model-kind option)
    (:boolean (objc:invoke control "setOn:" (and (option-model-value option) t)))
    ((:integer :number)
     (objc:invoke control "setValue:" (float (or (option-model-value option) 0) 1f0)))
    (:choice
     (objc:invoke control "setSelectedSegmentIndex:"
                  (or (position (option-model-value option) (option-model-choices option))
                      0)))))

;;; Contributed controls -------------------------------------------------------------

(defun build-sheet-controls (inspector model)
  "A row for each control contributed for the object.  Answers their views."
  (let ((stack (inspector-part inspector :controls)))
    (remove-arranged-subviews stack)
    (loop for control in (model-controls model)
          for tag from 0
          collect (ecase (control-model-kind control)
                    (:slider
                     (let ((slider (make-sheet-slider inspector "sheetControl:" tag
                                                      (control-model-min control)
                                                      (control-model-max control))))
                       (objc:invoke slider "setEnabled:" (and (control-model-enabled control) t))
                       (objc:invoke stack "addArrangedSubview:"
                                    (labelled-row (control-model-label control) slider))
                       slider))
                    (:toggle
                     (let ((switch (make-sheet-switch inspector "sheetControl:" tag)))
                       (objc:invoke switch "setEnabled:" (and (control-model-enabled control) t))
                       (objc:invoke stack "addArrangedSubview:"
                                    (labelled-row (control-model-label control) switch))
                       switch))
                    (:field
                     (let ((field (make-value-field (sheet-target inspector))))
                       (objc:invoke field "setHidden:" nil)
                       (objc:invoke field "setTag:" tag)
                       (objc:invoke field "setEnabled:" (and (control-model-enabled control) t))
                       (objc:invoke stack "addArrangedSubview:"
                                    (labelled-row (control-model-label control) field))
                       field))
                    (:button
                     (let ((button (uikit:system-button (control-model-label control))))
                       (objc:invoke button "setTag:" tag)
                       (sheet-action button inspector "sheetControl:")
                       (objc:invoke stack "addArrangedSubview:" button)
                       button))))))

(defun set-sheet-control (view control)
  (let ((value (control-model-value control)))
    (ecase (control-model-kind control)
      (:slider (when (realp value) (objc:invoke view "setValue:" (float value 1f0))))
      (:toggle (objc:invoke view "setOn:" (and value t)))
      (:field (unless (objc:invoke-bool view "isFirstResponder")
                (objc:invoke view "setText:" (inspector-print value 80))))
      (:button nil))))

;;; The sheet ------------------------------------------------------------------------

(defun build-inspector-sheet (inspector)
  "The sheet's controller and everything in it.  The +1 from -alloc is the
inspector's, until FORGET-INSPECTOR-SHEET."
  (let* ((object (make-instance 'inspector-sheet-controller))
         (target (objc:objc-object-pointer object))
         (controller (objc:invoke (objc:invoke "UIViewController" "alloc") "init"))
         (root (objc:invoke controller "view"))
         (outer (sheet-stack 1 8d0))
         (header (sheet-stack 0 10d0))
         (back (uikit:system-button "‹ Back"))
         (path (sheet-label "" :bold t))
         (all-views (uikit:system-button "Views"))
         (done (uikit:system-button "Done"))
         (message (sheet-label "" :size 12d0 :secondary t))
         (views (uikit:new "UISegmentedControl"))
         (options (sheet-stack 1 6d0))
         (controls (sheet-stack 1 6d0))
         (content (sheet-stack 1 6d0))
         (drawing-object (make-instance 'inspector-drawing-view))
         (drawing (objc:objc-object-pointer drawing-object))
         (native-host (uikit:new "UIView"))
         (table (uikit:new "UITableView"))
         (text (uikit:new "UITextView"))
         (caption (sheet-label "No row selected" :size 12d0 :secondary t))
         (field (make-value-field target))
         (buttons (sheet-stack 0 6d0)))
    (setf (sheet-controller-inspector object) inspector)
    (setf (inspector-retained inspector)
          (list :controller controller :controller-object object
                :path path :back back :done done :all-views all-views
                :message message :views views
                :options options :controls controls
                :drawing drawing :drawing-object drawing-object :native-host native-host
                :table table :text text :caption caption :field field
                :selection nil :rows-asked -1 :tries 0))
    (objc:invoke root "setBackgroundColor:" (objc:invoke "UIColor" "systemBackgroundColor"))
    ;; The header.
    (objc:invoke header "setAlignment:" 3)
    (objc:invoke path "setLineBreakMode:" 3)    ; truncating head: the end of the path matters
    (objc:invoke path "setContentHuggingPriority:forAxis:" 1.0 0)
    (objc:invoke path "setContentCompressionResistancePriority:forAxis:" 1.0 0)
    (sheet-action back inspector "sheetBack:")
    (sheet-action done inspector "sheetDone:")
    (sheet-action all-views inspector "sheetAllViews:")
    (dolist (view (list back path all-views done))
      (objc:invoke header "addArrangedSubview:" view))
    (objc:invoke message "setNumberOfLines:" 2)
    (objc:invoke views "setApportionsSegmentWidthsByContent:" t)
    (sheet-action views inspector "sheetView:" 4096)
    ;; What the scene comes to.  The ones it has share the room equally; a
    ;; hidden arranged view takes none.
    (objc:invoke content "setDistribution:" 1)  ; fill equally
    ;; And it is the content that takes whatever room is going (hugging
    ;; priority 1, vertically).  Left at the default, a scene with nothing in
    ;; it that wants height -- a picture -- left the choice to UIKit, which
    ;; stretched the header and put the title in the middle of the sheet.
    (objc:invoke content "setContentHuggingPriority:forAxis:" 1.0 1)
    (objc:invoke content "setContentCompressionResistancePriority:forAxis:" 1.0 1)
    (objc:invoke drawing "setTranslatesAutoresizingMaskIntoConstraints:" nil)
    (objc:invoke drawing "setContentMode:" 3)   ; redraw when the size changes
    (objc:invoke drawing "setOpaque:" t)
    ;; A long press of no length: it begins as the finger lands and follows it.
    ;; See BUILD-CANVAS-PANEL.
    (let ((touch (objc:invoke (objc:invoke "UILongPressGestureRecognizer" "alloc")
                              "initWithTarget:action:" target "sheetTouch:")))
      (objc:invoke touch "setMinimumPressDuration:" 0d0)
      (objc:invoke drawing "addGestureRecognizer:" touch)
      (objc:release touch))
    (objc:invoke table "setDataSource:" target)
    (objc:invoke table "setDelegate:" target)
    (objc:invoke table "setAllowsMultipleSelection:" nil)
    (objc:invoke text "setEditable:" nil)
    (objc:invoke text "setFont:" (uikit:mono-font (- *inspector-sheet-font-size* 1)))
    (dolist (view (list drawing native-host table text))
      (objc:invoke view "setHidden:" t)
      (objc:invoke content "addArrangedSubview:" view))
    ;; The foot.
    (objc:invoke field "setHidden:" nil)
    (objc:invoke field "setTag:" -1)
    (objc:invoke field "setPlaceholder:" "a form, evaluated")
    (objc:invoke buttons "setDistribution:" 1)
    (loop for (key title selector) in '((:open "Open" "sheetOpen:") (:set "Set" "sheetSet:")
                                        (:insert "Insert" "sheetInsert:")
                                        (:remove "Remove" "sheetRemove:")
                                        (:add "Add" "sheetAdd:"))
          do (let ((button (uikit:system-button title)))
               (sheet-action button inspector selector)
               (objc:invoke button "setEnabled:" nil)
               (objc:invoke buttons "addArrangedSubview:" button)
               (setf (inspector-part inspector key) button)))
    (dolist (view (list header message views options controls content caption field buttons))
      (objc:invoke outer "addArrangedSubview:" view))
    (objc:invoke root "addSubview:" outer)
    (let ((safe (objc:invoke root "safeAreaLayoutGuide"))
          (margin *inspector-sheet-margin*))
      (uikit:pin outer "topAnchor" root "topAnchor" (+ margin 6))
      (uikit:pin outer "leadingAnchor" safe "leadingAnchor" margin)
      (uikit:pin outer "trailingAnchor" safe "trailingAnchor" (- margin))
      ;; Above the keyboard, when the field has it.
      (uikit:pin outer "bottomAnchor" (objc:invoke root "keyboardLayoutGuide") "topAnchor"
                 (- margin)))
    ;; All of the screen: this is something to read, and its foot is a field.
    (let ((sheet (objc:invoke controller "sheetPresentationController")))
      (when (live-pointer-p sheet)
        (let ((detents (objc:invoke "NSMutableArray" "array")))
          (objc:invoke detents "addObject:"
                       (objc:invoke "UISheetPresentationControllerDetent" "largeDetent"))
          (objc:invoke sheet "setDetents:" detents)
          (objc:invoke sheet "setPrefersGrabberVisible:" t)
          (objc:invoke sheet "setDelegate:" target))))
    controller))

(defun inspector-sheet-up-p (&optional (inspector *inspector-shown*))
  (let ((controller (and inspector (inspector-part inspector :controller))))
    (and (live-pointer-p controller)
         (live-pointer-p (objc:invoke controller "presentingViewController")))))

(defun present-inspector-sheet (inspector)
  "Present the sheet, and if that did not take, try again shortly: UIKit will
not present over a sheet that is still on its way out -- the Try list, a moment
after an example that inspects was chosen from it -- and says so with a
warning, not a result.  See PRESENT-CANVAS-SHEET."
  (let ((controller (inspector-part inspector :controller))
        (listener (or (inspector-listener inspector) (current-listener))))
    (when (and (live-pointer-p controller) listener (not (inspector-sheet-up-p inspector)))
      (let ((presenter (settled-presenter (listener-view listener))))
        (when presenter
          (handler-case (objc:invoke presenter "presentViewController:animated:completion:"
                                     controller nil nil)
            (error (condition) (note "inspector: ~a" condition)))))
      (cond ((inspector-sheet-up-p inspector)
             (setf (inspector-part inspector :tries) 0)
             t)
            ((< (incf (inspector-part inspector :tries)) *inspector-present-limit*)
             (objc:invoke (sheet-target inspector) "performSelector:withObject:afterDelay:"
                          (objc:coerce-to-selector "sheetPresent") nil 0.25d0)
             nil)))))

(defvar *retired-sheet-controllers* '()
  "The controllers of the last few inspector sheets put away, newest first.
A sheet on its way out still has tables on screen, and they hold their data
source weakly: were it collected with its inspector, the next cell asked for
would be nobody's.  Held a while -- until three more have gone -- and no
longer, since a controller holds its inspector and so whatever was inspected.")

(defun forget-inspector-sheet (inspector)
  "The sheet has gone, or is going: let go of it, and end the inspector."
  (let ((controller (inspector-part inspector :controller))
        (object (inspector-part inspector :controller-object)))
    ;; The list over it goes with it.  The tables keep their data source: see
    ;; HIDE-VIEWS-LIST.
    (let ((list (inspector-part inspector :list-controller)))
      (when (live-pointer-p list)
        (objc:autorelease list)))
    (when (live-pointer-p controller)
      (objc:autorelease controller))
    (when object
      (setf *retired-sheet-controllers*
            (subseq (cons object (remove object *retired-sheet-controllers*))
                    0 (min 4 (1+ (length (remove object *retired-sheet-controllers*)))))))
    ;; The controller object is kept: a delayed "sheetPresent" may be on its way.
    (setf (inspector-retained inspector)
          (list :controller-object object))
    (when (eq *inspector-shown* inspector)
      (setf *inspector-shown* nil))
    (inspector-closed inspector)
    t))

(defun hide-inspector (&optional (inspector *inspector-shown*))
  "Dismiss INSPECTOR's sheet and end it.  Idempotent."
  (when inspector
    (let ((controller (inspector-part inspector :controller))
          (listener (or (inspector-listener inspector) (current-listener))))
      ;; Up, or on its way up: see DISMISS-SHEET-WHEN-SETTLED.  Not animated:
      ;; another inspector's sheet may be about to take its place.
      (when (and listener (live-pointer-p controller))
        (dismiss-sheet-when-settled (listener-view listener) controller nil)))
    (forget-inspector-sheet inspector))
  t)

(defun hide-inspectors ()
  (hide-inspector))

;;; Showing the model ----------------------------------------------------------------

(defun refresh-sheet-content (inspector pane)
  "The drawing, the native view, the table and the text: each shown if the
scene has it."
  (let ((drawing (inspector-part inspector :drawing))
        (object (inspector-part inspector :drawing-object))
        (host (inspector-part inspector :native-host))
        (table (inspector-part inspector :table))
        (text (inspector-part inspector :text)))
    (setf (drawing-view-scene object) (pane-model-drawing pane))
    (let ((readout (shiftf (drawing-view-readout object) nil)))
      (when (and readout (pane-model-drawing pane) (drawing-view-inside object))
        (inspector-request-readout inspector 0 (second readout) (third readout))))
    (objc:invoke drawing "setHidden:" (null (pane-model-drawing pane)))
    (objc:invoke drawing "setNeedsDisplay")
    ;; A native scene's view: made now, by the function the view answered.
    (let ((old (objc:invoke (objc:invoke host "subviews") "copy")))
      (dotimes (index (objc:invoke old "count"))
        (objc:invoke (objc:invoke old "objectAtIndex:" index) "removeFromSuperview"))
      (objc:release old))
    (objc:invoke host "setHidden:" (null (pane-model-native pane)))
    (when (pane-model-native pane)
      (let ((native (handler-case (funcall (pane-model-native pane))
                      (error (condition)
                        (note "inspector: a native view: ~a" condition)
                        nil))))
        (when (live-pointer-p native)
          (objc:invoke native "setTranslatesAutoresizingMaskIntoConstraints:" nil)
          ;; It is given the room; its own idea of its size -- an image
          ;; view's is its image's -- must not be what sizes the sheet.
          (dolist (axis '(0 1))
            (objc:invoke native "setContentHuggingPriority:forAxis:" 1.0 axis)
            (objc:invoke native "setContentCompressionResistancePriority:forAxis:" 1.0 axis))
          (objc:invoke host "addSubview:" native)
          (dolist (anchor '("topAnchor" "bottomAnchor" "leadingAnchor" "trailingAnchor"))
            (uikit:pin native anchor host anchor)))))
    (objc:invoke table "setHidden:" (null (pane-model-table pane)))
    (objc:invoke table "reloadData")
    (objc:invoke text "setHidden:" (zerop (length (pane-model-text pane))))
    (objc:invoke text "setText:" (pane-model-text pane))))

(defun refresh-inspector (inspector)
  "Show INSPECTOR's model in its sheet.  Nothing to do when it has none."
  (let ((model (inspector-model inspector))
        (pane (sheet-pane-model inspector)))
    (when (and model pane (live-pointer-p (inspector-part inspector :controller)))
      ;; Somewhere else than last time: the row that was selected is not here.
      ;; Told by the OBJECTS walked through, not their labels, which change
      ;; whenever what they print does.
      (unless (same-steps-p (model-steps model) (inspector-part inspector :steps-shown))
        (setf (inspector-part inspector :selection) nil
              (inspector-part inspector :rows-asked) -1
              (inspector-part inspector :steps-shown) (model-steps model)
              ;; And its controls are another object's.
              (inspector-part inspector :control-signature) nil)
        (objc:invoke (inspector-part inspector :field) "setText:" ""))
      (objc:invoke (inspector-part inspector :path) "setText:"
                   (format nil "~{~a~^ › ~}" (model-path model)))
      (objc:invoke (inspector-part inspector :back) "setEnabled:"
                   (and (rest (model-path model)) t))
      (objc:invoke (inspector-part inspector :message) "setText:" (or (model-message model) ""))
      (objc:invoke (inspector-part inspector :message) "setHidden:" (null (model-message model)))
      ;; The views that apply.
      (let ((views (inspector-part inspector :views))
            (titles (mapcar #'cdr (pane-model-choices pane))))
        (unless (equal titles (inspector-part inspector :views-shown))
          (objc:invoke views "removeAllSegments")
          (loop for title in titles
                for index from 0
                do (objc:invoke views "insertSegmentWithTitle:atIndex:animated:" title index nil))
          (setf (inspector-part inspector :views-shown) titles))
        (objc:invoke views "setSelectedSegmentIndex:"
                     (or (position (pane-model-view-name pane) (pane-model-choices pane)
                                   :key #'car)
                         0)))
      ;; The options and the controls: made again only when they are different
      ;; ones, and otherwise only told their values.
      (let ((signature (cons (pane-model-view-name pane)
                             (mapcar #'option-model-keyword (pane-model-options pane)))))
        (unless (equal signature (inspector-part inspector :option-signature))
          (setf (inspector-part inspector :option-controls) (build-sheet-options inspector pane)
                (inspector-part inspector :option-signature) signature))
        (loop for control in (inspector-part inspector :option-controls)
              for option in (pane-model-options pane)
              do (set-sheet-option control option))
        (objc:invoke (inspector-part inspector :options) "setHidden:"
                     (null (pane-model-options pane))))
      (let ((signature (cons :controls
                             (mapcar (lambda (control)
                                       (list (control-model-kind control)
                                             (control-model-label control)))
                                     (model-controls model)))))
        (unless (equal signature (inspector-part inspector :control-signature))
          (setf (inspector-part inspector :control-views) (build-sheet-controls inspector model)
                (inspector-part inspector :control-signature) signature))
        (loop for view in (inspector-part inspector :control-views)
              for control in (model-controls model)
              do (set-sheet-control view control))
        (objc:invoke (inspector-part inspector :controls) "setHidden:"
                     (null (model-controls model))))
      (refresh-sheet-content inspector pane)
      ;; The selection survives a reload, which a table's own does not.
      (let ((selected (inspector-part inspector :selection))
            (table-model (pane-model-table pane)))
        (if (and selected table-model (< selected (table-model-count table-model)))
            (objc:invoke (inspector-part inspector :table)
                         "selectRowAtIndexPath:animated:scrollPosition:"
                         (objc:invoke "NSIndexPath" "indexPathForRow:inSection:" selected 0)
                         nil 0)
            (setf (inspector-part inspector :selection) nil)))
      (show-inspector-selection inspector)
      t)))

(defun show-inspector (inspector)
  "Put INSPECTOR's sheet up, taking the place of any that is."
  (when (and *inspector-shown* (not (eq *inspector-shown* inspector)))
    (hide-inspector *inspector-shown*))
  (unless (live-pointer-p (inspector-part inspector :controller))
    (build-inspector-sheet inspector))
  (setf *inspector-shown* inspector)
  (refresh-inspector inspector)
  (present-inspector-sheet inspector)
  t)

;;; For the self-test -----------------------------------------------------------------

(defun press-inspector-button (key &optional (inspector *inspector-shown*))
  "Tap the sheet's button KEY -- :OPEN :SET :INSERT :REMOVE :ADD :BACK :DONE
:ALL-VIEWS --
as a finger would.  NIL if it is not there or not enabled."
  (let ((button (and inspector (inspector-part inspector key))))
    (when (and (live-pointer-p button) (objc:invoke-bool button "isEnabled"))
      (objc:invoke button "sendActionsForControlEvents:" 64)
      t)))

(defun select-inspector-row (index &optional (inspector *inspector-shown*))
  "Select row INDEX of the sheet's table, as a tap would."
  (let ((table (inspector-part inspector :table))
        (path (objc:invoke "NSIndexPath" "indexPathForRow:inSection:" index 0)))
    (objc:invoke table "selectRowAtIndexPath:animated:scrollPosition:" path nil 0)
    (objc:invoke (sheet-target inspector) "tableView:didSelectRowAtIndexPath:" table path)
    t))
