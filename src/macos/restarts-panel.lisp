;;;; src/macos/restarts-panel.lisp -- the restarts, docked in the listener window.
;;;;
;;;; The Mac's half of src/restarts.lisp, which explains the design: the
;;;; condition, the frames and the restarts, whose buttons TYPE the chosen
;;;; restart's number for you.  This file is the AppKit: the pane, its table and
;;;; its data sources, and the keys in the listener window.
;;;;
;;;; A PANE, not a window.  The listener window's content is a split view, and
;;;; while a debugger level is open the pane sits under the transcript with a
;;;; divider between them; when the level exits it goes and the transcript has
;;;; the window again.  As a window of its own it had to be kept over the
;;;; right listener, moved with it and ordered with it, and it still covered the
;;;; transcript it was about.  Docked, none of that arises.
;;;;
;;;; Docked in the window that has the keyboard, the pane must not take keys
;;;; that belong to the prompt.  A button's key equivalent is offered BEFORE the
;;;; text view sees the key, so Invoke's Return would have taken the Return that
;;;; submits a form typed at [1].  So the buttons have none; Escape still arrives
;;;; through the text view (see -complete: below), ⌘0 to ⌘9 choose a row, and the
;;;; table and the frames refuse the keyboard, so clicking them leaves it at the
;;;; prompt.
;;;;
;;;; LAYOUT-RESTARTS-PANEL places everything from the pane's bounds, on every
;;;; resize: the heading's height depends on how its report wraps at the new
;;;; width, which no autoresizing mask could say.

(in-package #:lisp-listener)

(defconstant +ns-view-width-sizable+ 2)
(defconstant +ns-view-min-x-margin+ 1)
(defconstant +ns-line-break-by-word-wrapping+ 0)
(defconstant +ns-line-break-by-truncating-tail+ 4)
(defconstant +ns-text-alignment-right+ 2)
(defconstant +ns-table-uniform-column-autoresizing+ 1)

(defparameter *restarts-panel-width* 580d0
  "The width the pane's pieces are made at, before the first layout.")
(defparameter *restarts-pane-share* 0.62d0
  "The most of the window's height the pane opens at.  The divider moves.")
(defparameter *restarts-panel-margin* 14d0)
(defparameter *heading-type-height* 16d0)
(defparameter *heading-report-max-height* 120d0
  "The most height the wrapped report takes before it is cut off.  The
transcript has all of it.")
(defparameter *restart-row-height* 24d0)
(defparameter *restart-number-width* 26d0)
(defparameter *restart-name-width* 118d0)
(defparameter *restarts-table-max-height* 150d0
  "The table scrolls, so this is a window onto the restarts, not a limit.")
(defparameter *value-row-height* 24d0)
(defparameter *value-label-width* 130d0)
(defparameter *push-button-height* 32d0)
(defparameter *push-button-width* 96d0)
(defparameter *panel-gap* 10d0)
(defparameter *backtrace-pane-height* 150d0
  "The MOST the frames get when the pane opens.  They scroll, so this is a
window onto them rather than a limit -- but a fixed height left three frames
sitting in a mostly empty box, so BACKTRACE-PANE-HEIGHT fits the content up to
this.  Moving the divider gives them more.")

(defparameter *backtrace-line-height* 17d0)

(defun backtrace-pane-height (frames)
  (if frames
      (min *backtrace-pane-height*
           (max (* 3 *backtrace-line-height*)
                (+ 4d0 (* (length frames) *backtrace-line-height*))))
      0d0))

(defun restarts-table-height (count)
  (min *restarts-table-max-height*
       (max (* 2 *restart-row-height*)
            (+ 4d0 (* count *restart-row-height*)))))

;;; NSInteger is (:SIGNED :LONG-LONG).  NOT (:SIGNED :LONG): objc's CLAUDE.md
;;; records that 'l' and 'L' are 32 bits even on LP64 while NSInteger encodes
;;; as 'q', and collections.lisp's -hash and pasteboard.lisp's -draggingEntered:
;;; both spell their NSUInteger the long-long way.

(objc:define-objc-method ("numberOfRowsInTableView:" (:signed :long-long))
    ((self restarts-controller) (table objc:objc-object-pointer))
  (declare (ignorable table))
  (handler-case (length (controller-titles self))
    (error (condition) (note "numberOfRowsInTableView: ~a" condition) 0)))

(objc:define-objc-method ("tableView:viewForTableColumn:row:" objc:objc-object-pointer)
    ((self restarts-controller)
     (table objc:objc-object-pointer)
     (column objc:objc-object-pointer)
     (row (:signed :long-long)))
  (declare (ignorable table column))
  (handler-case
      (let ((titles (controller-titles self)))
        (if (and (>= row 0) (< row (length titles)))
            (make-row-view (nth row titles))
            (cffi:null-pointer)))
    (error (condition)
      (note "viewForTableColumn: ~a" condition)
      (cffi:null-pointer))))

(objc:define-objc-method ("invokeSelectedRestart:" :void)
    ((self restarts-controller) (sender objc:objc-object-pointer))
  (declare (ignorable sender))
  (handler-case
      (let* ((*listener* (or (controller-listener self) *listener*))
             (listener *listener*)
             (table (and listener (listener-restarts-table listener))))
        (when (and table (cffi:pointerp table) (not (cffi:null-pointer-p table)))
          (let ((row (objc:invoke table "selectedRow"))
                (asking (getf (controller-views self) :value-index)))
            ;; Invoke -- or Return, its key -- while a value is being asked
            ;; for, on the row that asked, sends the value.  On any other row,
            ;; the question is dropped and that row is taken instead.
            (if (and asking (= row asking))
                (submit-restart-value listener)
                (progn (hide-restart-value listener)
                       (activate-restart row listener))))))
    (error (condition) (note "invokeSelectedRestart: ~a" condition))))

(objc:define-objc-method ("restartValueEntered:" :void)
    ((self restarts-controller) (sender objc:objc-object-pointer))
  (declare (ignorable sender))
  (handler-case
      (let ((*listener* (or (controller-listener self) *listener*)))
        (submit-restart-value *listener*))
    (error (condition) (note "restartValueEntered: ~a" condition))))

(objc:define-objc-method ("dismissRestarts:" :void)
    ((self restarts-controller) (sender objc:objc-object-pointer))
  (declare (ignorable sender))
  ;; Cancel RETURNS TO THE TOP LEVEL, through the restart -- it does not merely
  ;; close the panel.  Closing it alone would leave the listener sitting at its
  ;; [1] prompt with the way out just taken off the screen, which is the
  ;; opposite of what a Cancel button promises.
  ;;
  ;; Through the restart, and not through an interrupt: the abort restart is
  ;; the listener's own, the reader is waiting for exactly this answer, and
  ;; taking it is the same act as typing its number.
  (handler-case
      (let ((*listener* (or (controller-listener self) *listener*))
            (index (controller-cancel-index self)))
        (if index
            (choose-restart index)
            (hide-restarts-panel *listener*)))
    (error (condition) (note "dismissRestarts: ~a" condition))))

(objc:define-objc-method ("restartsPaneResized:" :void)
    ((self restarts-controller) (notification objc:objc-object-pointer))
  (declare (ignorable notification))
  (handler-case (layout-restarts-panel self)
    (error (condition) (note "restartsPaneResized: ~a" condition))))

;;; Escape in the value field puts the question away and nothing more.  As a
;;; key equivalent on Cancel, it went all the way to the top level from there.
(objc:define-objc-method ("control:textView:doCommandBySelector:" objc:objc-bool)
    ((self restarts-controller)
     (control objc:objc-object-pointer)
     (text-view objc:objc-object-pointer)
     (command objc:sel))
  (declare (ignorable control text-view))
  (handler-case
      (when (string= "cancelOperation:" (objc:selector-name command))
        (let ((listener (or (controller-listener self) *listener*)))
          (hide-restart-value listener)
          t))
    (error (condition) (note "doCommandBySelector: ~a" condition) nil)))

;;; The pieces ------------------------------------------------------------------

(defun system-font (size &key bold)
  (objc:invoke "NSFont" (if bold "boldSystemFontOfSize:" "systemFontOfSize:")
               (float size 1d0)))

(defun system-color (name)
  (objc:invoke "NSColor" name))

(defun make-label (text &key font color selectable wraps alignment
                             (frame (vector 0d0 0d0 10d0 10d0)))
  "A borderless, read-only NSTextField, +1.

Truncated at the tail unless it WRAPS: a report or a restart can be far wider
than its column, and text that simply stops mid-word reads as a rendering fault
rather than as `there is more here'."
  (let ((field (objc:invoke (objc:invoke "NSTextField" "alloc") "initWithFrame:" frame)))
    (objc:invoke field "setStringValue:" (or text ""))
    (objc:invoke field "setBezeled:" nil)
    (objc:invoke field "setDrawsBackground:" nil)
    (objc:invoke field "setEditable:" nil)
    (objc:invoke field "setSelectable:" (and selectable t))
    (when font (objc:invoke field "setFont:" font))
    (when color (objc:invoke field "setTextColor:" color))
    (when alignment (objc:invoke field "setAlignment:" alignment))
    (let ((cell (objc:invoke field "cell")))
      (cond (wraps
             (objc:invoke field "setUsesSingleLineMode:" nil)
             (objc:invoke cell "setWraps:" t)
             (objc:invoke cell "setLineBreakMode:" +ns-line-break-by-word-wrapping+))
            (t (objc:invoke cell "setLineBreakMode:" +ns-line-break-by-truncating-tail+))))
    field))

(defun add-label (container label &optional (mask 0))
  (objc:invoke label "setAutoresizingMask:" mask)
  (objc:invoke container "addSubview:" label)
  (objc:release label))

(defun make-row-view (row)
  "One row of the table, AUTORELEASED: the number, the restart's report, and
its name, small, at the right.

The report is what a person reads to choose, so it is the one in the ordinary
system font; the number and the name are how the same restart is reached by
typing or by (invoke-restart 'name), and are set back in grey.  A row outside
the listener -- the thread's own abort -- is greyed as a whole: taking it ends
the listener.

The autorelease is not tidiness.  This comes back from a delegate method
returning an id the caller does not own, and AppKit asks for it again on every
redraw; a +1 object here would leak one per row per repaint.  objc's
convert.lisp is explicit that an object returned from a Lisp method is the
caller's to release, and NSTableView will not."
  (let* ((width (- *restarts-panel-width* (* 2 *restarts-panel-margin*) 24d0))
         (height *restart-row-height*)
         (secondary (system-color "secondaryLabelColor"))
         (container (objc:invoke (objc:invoke "NSView" "alloc") "initWithFrame:"
                                 (vector 0d0 0d0 width height)))
         (report-x (+ *restart-number-width* 8d0))
         (name-x (- width *restart-name-width* 4d0)))
    ;; Each field is centred on the row by its own font's line height, so the
    ;; three baselines come out level.
    (add-label container
               (make-label (format nil "~d" (restart-row-index row))
                           :font (objc:invoke "NSFont" "monospacedDigitSystemFontOfSize:weight:"
                                              11d0 0d0)
                           :color secondary
                           :alignment +ns-text-alignment-right+
                           :frame (vector 0d0 4.5d0 *restart-number-width* 15d0)))
    (add-label container
               (make-label (format nil "~a~@[ …~]" (restart-row-report row)
                                   (restart-row-asks-p row))
                           :font (system-font 13)
                           :color (if (restart-row-outside-p row)
                                      secondary
                                      (system-color "labelColor"))
                           :frame (vector report-x 3.5d0 (- name-x report-x 8d0) 17d0))
               +ns-view-width-sizable+)
    (add-label container
               (make-label (restart-row-name row)
                           :font (system-font 10)
                           :color secondary
                           :alignment +ns-text-alignment-right+
                           :frame (vector name-x 5d0 *restart-name-width* 14d0))
               +ns-view-min-x-margin+)
    (objc:autorelease container)))

(defun select-restart-row (table row)
  (objc:invoke table "selectRowIndexes:byExtendingSelection:"
               (objc:invoke "NSIndexSet" "indexSetWithIndex:" row)
               nil)
  table)

(defun make-restarts-table (listener count target selected)
  "The restarts, as a list, in its scroll view (+1).  Main thread only.

A list rather than a column of buttons because that is what a Mac uses to
choose one thing from several, and because LispWorks' notifier is itself a
list box.  The push buttons below it are push buttons doing what push buttons
are for."
  (let* ((frame (vector 0d0 0d0 (- *restarts-panel-width* (* 2 *restarts-panel-margin*))
                        (restarts-table-height count)))
         (scroll (objc:invoke (objc:invoke "NSScrollView" "alloc")
                              "initWithFrame:" frame))
         (table (objc:invoke (objc:invoke "NSTableView" "alloc")
                             "initWithFrame:" frame))
         (column (objc:invoke (objc:invoke "NSTableColumn" "alloc")
                              "initWithIdentifier:" "restart")))
    (objc:invoke column "setWidth:" (- (aref frame 2) 24d0))
    ;; The one column follows the table's width as the panel is resized.
    (objc:invoke column "setResizingMask:" 1)   ; NSTableColumnAutoresizingMask
    (objc:invoke table "addTableColumn:" column)
    (objc:release column)
    (objc:invoke table "setColumnAutoresizingStyle:" +ns-table-uniform-column-autoresizing+)
    ;; No header: one unnamed column of restarts needs no column title.
    (objc:invoke table "setHeaderView:" nil)
    (objc:invoke table "setRowHeight:" *restart-row-height*)
    (objc:invoke table "setUsesAlternatingRowBackgroundColors:" t)
    (objc:invoke table "setAllowsMultipleSelection:" nil)
    ;; Clicking a row selects it and leaves the keyboard at the prompt.
    (objc:invoke table "setRefusesFirstResponder:" t)
    (objc:invoke table "setDataSource:" target)
    (objc:invoke table "setDelegate:" target)
    (objc:invoke table "setTarget:" target)
    (objc:invoke table "setDoubleAction:"
                 (objc:coerce-to-selector "invokeSelectedRestart:"))
    (objc:invoke scroll "setHasVerticalScroller:" t)
    ;; Otherwise a scroller's width is kept free on the right whether or not
    ;; there is anything to scroll, and the rows stop short of the edge.
    (objc:invoke scroll "setAutohidesScrollers:" t)
    (objc:invoke scroll "setBorderType:" 2)       ; NSBezelBorder
    (objc:invoke scroll "setDocumentView:" table)
    (objc:invoke table "reloadData")
    ;; Something selected from the start, so Invoke means something the moment
    ;; the panel appears -- and the SAFE something: the way back to the top
    ;; level.  Row 0 is whatever the error put first, and on an unbound
    ;; variable that is `Retry using *FOO*', which fails again.
    (when (plusp count)
      (let ((row (if (and selected (< -1 selected count)) selected 0)))
        (select-restart-row table row)
        (objc:invoke table "scrollRowToVisible:" row)))
    (setf (listener-restarts-table listener) table)
    ;; -setDocumentView: retains it; the +1 from -alloc is ours to drop.
    (objc:release table)
    scroll))

(defun make-push-button (title selector target x y key)
  "An ordinary push button at its natural height, which is what the bezel
style is designed for.  The history panel uses it too."
  (let ((button (objc:invoke (objc:invoke "NSButton" "alloc") "initWithFrame:"
                             (vector x y *push-button-width* *push-button-height*))))
    (objc:invoke button "setTitle:" title)
    (objc:invoke button "setBezelStyle:" 1)
    (objc:invoke button "setTarget:" target)
    (objc:invoke button "setAction:" (objc:coerce-to-selector selector))
    (when key (objc:invoke button "setKeyEquivalent:" key))
    button))

(defun make-backtrace-pane (frames target)
  "The frames, as an outline in its scroll view (+1).  Main thread only.

A frame whose locals were captured opens to show them, `N = 21', one to a row
-- what SLIME's debugger shows under a frame, and what the stack held when it
failed.  The locals are text already, printed on the listener thread while the
stack existed; nothing here reaches back into it.

The LispWorks Debugger tool puts a backtrace beside its restarts, which is the
arrangement this borrows: the restarts say what you can do, the frames say
where you are, and neither is much use without the other.

Returns the scroll view, the outline, its items -- see BACKTRACE-ITEMS -- and a
function that connects the outline to TARGET once TARGET knows the items."
  (let* ((frame (vector 0d0 0d0 (- *restarts-panel-width* (* 2 *restarts-panel-margin*))
                        (backtrace-pane-height frames)))
         (scroll (objc:invoke (objc:invoke "NSScrollView" "alloc")
                              "initWithFrame:" frame))
         (outline (objc:invoke (objc:invoke "NSOutlineView" "alloc")
                               "initWithFrame:" frame))
         (column (objc:invoke (objc:invoke "NSTableColumn" "alloc")
                              "initWithIdentifier:" "frame")))
    (objc:invoke column "setResizingMask:" 1)   ; NSTableColumnAutoresizingMask
    (objc:invoke outline "addTableColumn:" column)
    (objc:invoke outline "setOutlineTableColumn:" column)
    (objc:release column)
    (objc:invoke outline "setColumnAutoresizingStyle:" +ns-table-uniform-column-autoresizing+)
    (objc:invoke outline "setHeaderView:" nil)
    (objc:invoke outline "setRowHeight:" (- *backtrace-line-height* 2d0))
    (objc:invoke outline "setIndentationPerLevel:" 16d0)
    (objc:invoke outline "setRefusesFirstResponder:" t)
    (objc:invoke scroll "setHasVerticalScroller:" t)
    (objc:invoke scroll "setAutohidesScrollers:" t)
    (objc:invoke scroll "setBorderType:" 2)       ; NSBezelBorder
    (objc:invoke scroll "setDocumentView:" outline)
    ;; -setDocumentView: retains it; the +1 from -alloc is ours to drop.
    (objc:release outline)
    (values scroll outline (backtrace-items frames)
            (lambda ()
              ;; Connected once the controller has the items: the outline asks
              ;; for them at once.
              (objc:invoke outline "setDataSource:" target)
              (objc:invoke outline "setDelegate:" target)
              (objc:invoke outline "reloadData")))))

;;; The outline's items.  NSOutlineView keeps track of a row by the IDENTITY of
;;; the object it was handed for it -- which rows are expanded, which is which
;;; after a reload -- so each frame and each local needs an object of its own
;;; that stays put, not a number made afresh every time it is asked.  Each is
;;; an NSString made once, held here, and released with the pane.

(defstruct (backtrace-items (:constructor %make-backtrace-items))
  (frames '())        ; the BACKTRACE-FRAMEs
  (roots #())         ; an item per frame
  (children #())      ; per frame, a vector of an item per local
  (lookup (make-hash-table)))   ; an item's address -> (FRAME . LOCAL-OR-NIL)

(defun make-item (text)
  (objc:invoke (objc:invoke "NSString" "alloc") "initWithString:" text))

(defun backtrace-items (frames)
  (let* ((lookup (make-hash-table))
         (roots (make-array (length frames)))
         (children (make-array (length frames))))
    (loop for frame in frames
          for i from 0
          do (let ((item (make-item (format nil "f~d" i))))
               (setf (aref roots i) item
                     (gethash (cffi:pointer-address item) lookup) (cons i nil)))
             (setf (aref children i)
                   (coerce (loop for j from 0 below (length (backtrace-frame-locals frame))
                                 collect (let ((item (make-item (format nil "f~d.~d" i j))))
                                           (setf (gethash (cffi:pointer-address item) lookup)
                                                 (cons i j))
                                           item))
                           'vector)))
    (%make-backtrace-items :frames frames :roots roots :children children
                           :lookup lookup)))

(defun release-backtrace-items (items)
  (when items
    (loop for item across (backtrace-items-roots items) do (objc:release item))
    (loop for locals across (backtrace-items-children items)
          do (loop for item across locals do (objc:release item)))))

(defun item-place (items item)
  "(FRAME . LOCAL) for ITEM, LOCAL NIL for a frame; NIL for the root."
  (and (cffi:pointerp item) (not (cffi:null-pointer-p item))
       (gethash (cffi:pointer-address item) (backtrace-items-lookup items))))

(defun controller-backtrace-items (controller)
  (getf (controller-views controller) :backtrace-items))

(objc:define-objc-method ("outlineView:numberOfChildrenOfItem:" (:signed :long-long))
    ((self restarts-controller) (outline objc:objc-object-pointer)
     (item objc:objc-object-pointer))
  (declare (ignorable outline))
  (handler-case
      (let* ((items (controller-backtrace-items self))
             (place (and items (item-place items item))))
        (cond ((null items) 0)
              ((null place) (length (backtrace-items-roots items)))
              ((null (cdr place))
               (length (aref (backtrace-items-children items) (car place))))
              (t 0)))
    (error (condition) (note "numberOfChildrenOfItem: ~a" condition) 0)))

(objc:define-objc-method ("outlineView:child:ofItem:" objc:objc-object-pointer)
    ((self restarts-controller) (outline objc:objc-object-pointer)
     (index (:signed :long-long)) (item objc:objc-object-pointer))
  (declare (ignorable outline))
  (handler-case
      (let* ((items (controller-backtrace-items self))
             (place (item-place items item)))
        (if (null place)
            (aref (backtrace-items-roots items) index)
            (aref (aref (backtrace-items-children items) (car place)) index)))
    (error (condition) (note "child:ofItem: ~a" condition) (cffi:null-pointer))))

(objc:define-objc-method ("outlineView:isItemExpandable:" objc:objc-bool)
    ((self restarts-controller) (outline objc:objc-object-pointer)
     (item objc:objc-object-pointer))
  (declare (ignorable outline))
  (handler-case
      (let* ((items (controller-backtrace-items self))
             (place (and items (item-place items item))))
        (and place (null (cdr place))
             (plusp (length (aref (backtrace-items-children items) (car place))))))
    (error (condition) (note "isItemExpandable: ~a" condition) nil)))

(objc:define-objc-method ("outlineView:viewForTableColumn:item:" objc:objc-object-pointer)
    ((self restarts-controller) (outline objc:objc-object-pointer)
     (column objc:objc-object-pointer) (item objc:objc-object-pointer))
  (declare (ignorable outline column))
  (handler-case
      (let* ((items (controller-backtrace-items self))
             (place (item-place items item))
             (frame (and place (nth (car place) (backtrace-items-frames items))))
             (local (and frame (cdr place)
                         (nth (cdr place) (backtrace-frame-locals frame)))))
        (if frame
            (objc:autorelease
             (make-label (or local (backtrace-frame-line frame))
                         :font (objc:invoke "NSFont" "monospacedSystemFontOfSize:weight:"
                                            11d0 0d0)
                         :color (system-color (if local "secondaryLabelColor" "labelColor"))))
            (cffi:null-pointer)))
    (error (condition) (note "viewForTableColumn:item: ~a" condition) (cffi:null-pointer))))

;;; Layout -------------------------------------------------------------------------

(defun report-label-height (label width)
  "How tall LABEL's wrapped report is at WIDTH, up to *HEADING-REPORT-MAX-HEIGHT*."
  (let ((size (objc:invoke (objc:invoke label "cell") "cellSizeForBounds:"
                           (vector 0d0 0d0 width 10000d0))))
    (min *heading-report-max-height* (max 17d0 (fceiling (aref size 1))))))

(defun panel-content-height (report-height backtrace-height table-height)
  (+ *restarts-panel-margin*
     *heading-type-height* 2d0 report-height *panel-gap*
     (if (plusp backtrace-height) (+ backtrace-height *panel-gap*) 0d0)
     table-height *panel-gap*
     *push-button-height* *restarts-panel-margin*))

(defun layout-restarts-panel (controller)
  "Place everything in the panel from its content view's bounds.  Main thread.

Top down, since an NSView's origin is its bottom left: the type, the wrapped
report, the frames, the list, and the buttons along the bottom.  Height the
panel has beyond what it opened at is shared between the frames and the list,
the two things worth more room."
  (let ((views (controller-views controller)))
    (when views
      (destructuring-bind (&key content type report backtrace table table-view
                                value-label value-field value-index hint
                                cancel invoke backtrace-natural table-natural
                                &allow-other-keys)
          views
        (let* ((bounds (objc:invoke content "bounds"))
               (width (aref bounds 2))
               (height (aref bounds 3))
               (margin *restarts-panel-margin*)
               (inner (- width (* 2 margin)))
               (top (- height margin))
               (report-height (report-label-height report inner))
               (value-y (+ margin *push-button-height* *panel-gap*))
               (bottom (+ value-y
                          (if value-index (+ *value-row-height* *panel-gap*) 0d0))))
          (objc:invoke type "setFrame:"
                       (vector margin (- top *heading-type-height*)
                               inner *heading-type-height*))
          (decf top (+ *heading-type-height* 2d0))
          (objc:invoke report "setFrame:"
                       (vector margin (- top report-height) inner report-height))
          (decf top (+ report-height *panel-gap*))
          (let* ((available (- top bottom))
                 (between (if backtrace *panel-gap* 0d0))
                 (extra (- available backtrace-natural table-natural between))
                 (backtrace-height
                   (if backtrace
                       (max (* 2 *backtrace-line-height*)
                            (+ backtrace-natural (/ extra 2)))
                       0d0))
                 (table-height (max *restart-row-height*
                                    (- available backtrace-height between))))
            (when backtrace
              (objc:invoke backtrace "setFrame:"
                           (vector margin (- top backtrace-height) inner backtrace-height))
              ;; The frames' one column to the full width too, or every frame is
              ;; cut off at the default column's hundred points.  Set outright:
              ;; -sizeLastColumnToFit leaves a column made at that default
              ;; where it was.
              (let ((outline (objc:invoke backtrace "documentView")))
                (objc:invoke (objc:invoke (objc:invoke outline "tableColumns")
                                          "objectAtIndex:" 0)
                             "setWidth:" (max 50d0 (- inner 4d0)))))
            (objc:invoke table "setFrame:"
                         (vector margin bottom inner table-height))
            ;; The one column to the table's full width: set once at the width
            ;; the panel opened at, it left a gap on the right that grew with
            ;; every resize.
            (objc:invoke table-view "sizeLastColumnToFit"))
          ;; The value a restart asked for: its name, and the field.
          (objc:invoke value-label "setFrame:"
                       (vector margin (+ value-y 2d0) *value-label-width* 18d0))
          (objc:invoke value-field "setFrame:"
                       (vector (+ margin *value-label-width* 8d0) value-y
                               (- inner *value-label-width* 8d0) *value-row-height*))
          ;; Cancel and Invoke, bottom right, Invoke rightmost as a Mac puts it,
          ;; and the keys that do the same, in the room to their left.
          (let* ((invoke-x (- width margin *push-button-width*))
                 (cancel-x (- invoke-x *push-button-width* 4d0)))
            (objc:invoke hint "setFrame:"
                         (vector margin (+ margin 8d0)
                                 (max 0d0 (- cancel-x margin 8d0)) 16d0))
            (objc:invoke invoke "setFrame:"
                         (vector invoke-x margin *push-button-width* *push-button-height*))
            (objc:invoke cancel "setFrame:"
                         (vector cancel-x margin *push-button-width* *push-button-height*))))))))

(defun build-restarts-panel (listener heading backtrace rows cancel-index)
  "The pane: the condition, the frames, the restarts as a list, and the two
push buttons that act on the selection.  Main thread only.  Returns the pane
(+1) and the height it would like.

Takes rows and a heading already printed, rather than the restarts and the
condition themselves: see RESTART-ROWS for why they cannot be printed here."
  (let* ((controller (getf (listener-retained listener) :restarts-controller))
         (target (objc:objc-object-pointer controller))
         (count (length rows))
         (inner (- *restarts-panel-width* (* 2 *restarts-panel-margin*)))
         ;; The level first: it was the panel's title, and there is no panel
         ;; window now.
         (type (make-label (format nil "~a · ~a" (heading-title heading)
                                   (debugger-heading-type heading))
                           :font (system-font 11)
                           :color (system-color "secondaryLabelColor")
                           :selectable t))
         (report (make-label (debugger-heading-report heading)
                             :font (system-font 13 :bold t)
                             :selectable t :wraps t))
         (backtrace-natural (backtrace-pane-height backtrace))
         (table-natural (restarts-table-height count))
         (height (panel-content-height (report-label-height report inner)
                                       backtrace-natural table-natural))
         (pane (objc:invoke (objc:invoke "NSView" "alloc") "initWithFrame:"
                            (vector 0d0 0d0 *restarts-panel-width* height))))
    (multiple-value-bind (frames outline items connect)
        (if backtrace (make-backtrace-pane backtrace target) (values nil nil nil nil))
      (declare (ignore outline))
      (let* (;; The rows go on the controller BEFORE the table exists: the table
             ;; loads, and selects its first row, as it is made.
             (table (progn
                      (setf (controller-titles controller) rows
                            (controller-cancel-index controller) cancel-index)
                      (make-restarts-table listener count target cancel-index)))
             (value-label (make-label "" :font (system-font 12)
                                      :alignment +ns-text-alignment-right+))
             (value-field (make-value-field target))
             (hint (make-label (restarts-hint nil (length rows))
                               :font (system-font 11)
                               :color (system-color "secondaryLabelColor")))
             ;; No key equivalents: see the header.
             (cancel (make-push-button "Cancel" "dismissRestarts:" target 0d0 0d0 nil))
             (invoke (make-push-button "Invoke" "invokeSelectedRestart:" target 0d0 0d0 nil)))
        (objc:invoke value-label "setHidden:" t)
        (objc:invoke value-field "setHidden:" t)
        (dolist (view (remove nil (list type report frames table value-label value-field
                                        hint cancel invoke)))
          (objc:invoke pane "addSubview:" view)
          (objc:release view))
        (setf (listener-restarts-invoke listener) invoke
              (controller-views controller)
              (list :content pane :type type :report report :backtrace frames
                    :backtrace-items items
                    :table table :table-view (listener-restarts-table listener)
                    :value-label value-label :value-field value-field :value-index nil
                    :hint hint :cancel cancel :invoke invoke
                    :backtrace-natural backtrace-natural :table-natural table-natural))
        (when connect (funcall connect))
        (layout-restarts-panel controller)
        (values pane height)))))

;;; Asking for a value ----------------------------------------------------------
;;;
;;; USE-VALUE and STORE-VALUE want a form.  Clicking one used to close the panel
;;; and ask in the transcript, `Enter a form to be evaluated:', so the choice
;;; began in one place and ended in another.  Now the panel asks: a field
;;; opens under the list, Return sends `1 42' -- the restart and the form, in
;;; the one line the debugger reads as both -- and the transcript records that
;;; line as though it had been typed at the prompt.

(defun make-value-field (target)
  "The field a restart's value is typed into (+1).  Return in it sends."
  (let ((field (objc:invoke (objc:invoke "NSTextField" "alloc") "initWithFrame:"
                            (vector 0d0 0d0 100d0 *value-row-height*))))
    (objc:invoke field "setFont:"
                 (objc:invoke "NSFont" "monospacedSystemFontOfSize:weight:" 12d0 0d0))
    (objc:invoke field "setPlaceholderString:" "a form, evaluated in the listener")
    (objc:invoke field "setTarget:" target)
    (objc:invoke field "setAction:" (objc:coerce-to-selector "restartValueEntered:"))
    ;; For Escape: see -control:textView:doCommandBySelector:.
    (objc:invoke field "setDelegate:" target)
    field))

(defun restarts-hint (asking count)
  "The line beside the buttons that says which keys do what."
  (cond (asking "Return uses the value · Esc puts the question away")
        ((> count 1) "⌘0–⌘9 or double-click to choose · Esc returns to the top level")
        (t "Esc returns to the top level")))

(defun request-restart-value (listener index)
  "Ask, in the panel, for the value restart INDEX wants.  Thread 1.

The field takes the keyboard for this, and only for this: everywhere else the
pane leaves it at the prompt, so a number can still be typed there.  The room
for it comes out of the frames and the list; the pane does not grow."
  (let* ((controller (getf (listener-retained listener) :restarts-controller))
         (panel (listener-restarts-panel listener))
         (views (and controller (controller-views controller)))
         (row (and controller (nth index (controller-titles controller)))))
    (when (and views row panel)
      (let ((field (getf views :value-field)))
        ;; The index first: the layout makes room for the field only when
        ;; there is a question.
        (setf (getf (controller-views controller) :value-index) index)
        (objc:invoke (getf views :value-label) "setStringValue:"
                     (format nil "~a:" (restart-row-name row)))
        (objc:invoke (getf views :value-label) "setHidden:" nil)
        (objc:invoke field "setHidden:" nil)
        (objc:invoke field "setStringValue:" "")
        (objc:invoke (getf views :hint) "setStringValue:"
                     (restarts-hint t (length (controller-titles controller))))
        (select-restart-row (listener-restarts-table listener) index)
        (layout-restarts-panel controller)
        (objc:invoke (listener-window listener) "makeFirstResponder:" field)))
    t))

(defun hide-restart-value (listener)
  "Put the question away, if one is being asked, and give the keyboard back to
the prompt.  Thread 1."
  (let* ((controller (getf (listener-retained listener) :restarts-controller))
         (views (and controller (controller-views controller))))
    (when (and views (getf views :value-index))
      (setf (getf (controller-views controller) :value-index) nil)
      (objc:invoke (getf views :value-label) "setHidden:" t)
      (objc:invoke (getf views :value-field) "setHidden:" t)
      (objc:invoke (getf views :hint) "setStringValue:"
                   (restarts-hint nil (length (controller-titles controller))))
      (layout-restarts-panel controller)
      (objc:invoke (listener-window listener) "makeFirstResponder:"
                   (listener-view listener)))))

(defun submit-restart-value (listener)
  "Take the restart that asked, with the form in the field.  Thread 1.

An empty field sends nothing: an empty answer is not an answer, and the
restart would only ask for one again in the transcript."
  (let* ((controller (getf (listener-retained listener) :restarts-controller))
         (views (and controller (controller-views controller)))
         (index (getf views :value-index))
         (text (and index
                    (string-trim '(#\Space #\Tab #\Newline)
                                 (objc:ns-string-to-string
                                  (objc:invoke (getf views :value-field) "stringValue")))))
         (window (listener-window listener)))
    (when (and text (plusp (length text)))
      (let ((*listener* listener))
        (choose-restart index text))
      ;; The field had the keyboard; the prompt gets it back.
      (objc:invoke window "makeFirstResponder:" (listener-view listener))
      t)))

;;; Showing and hiding ----------------------------------------------------------

(defun listener-split-view (listener)
  "The split view that is the listener window's content, or NIL."
  (let* ((window (listener-window listener))
         (content (and window (objc:invoke window "contentView"))))
    (and content (not (cffi:null-pointer-p content))
         (objc:invoke-bool content "isKindOfClass:"
                           (objc:coerce-to-objc-class "NSSplitView"))
         content)))

(defun notification-center ()
  (objc:invoke "NSNotificationCenter" "defaultCenter"))

(defun show-restarts-panel (listener heading backtrace rows cancel-index)
  "Dock ROWS, under HEADING and the frames, below the transcript.  Thread 1.

The pane opens at the height it wants, up to *RESTARTS-PANE-SHARE* of the
window; the divider is the person's to move after that.  The keyboard stays at
the prompt, and the transcript is scrolled back to it, since it has just lost
the bottom of the window."
  (hide-restarts-panel listener)
  (let ((split (listener-split-view listener)))
    (when split
      (multiple-value-bind (pane height)
          (build-restarts-panel listener heading backtrace rows cancel-index)
        (let* ((controller (getf (listener-retained listener) :restarts-controller))
               (total (aref (objc:invoke split "bounds") 3))
               (divider (objc:invoke split "dividerThickness"))
               (share (min height (* *restarts-pane-share* total))))
          (setf (listener-restarts-panel listener) pane)
          (objc:invoke split "addSubview:" pane)
          ;; The split view holds it now.
          (objc:release pane)
          (objc:invoke split "adjustSubviews")
          (objc:invoke split "setPosition:ofDividerAtIndex:" (- total share divider) 0)
          ;; Laid out again whenever the divider or the window moves it.
          (objc:invoke pane "setPostsFrameChangedNotifications:" t)
          (objc:invoke (notification-center) "addObserver:selector:name:object:"
                       (objc:objc-object-pointer controller)
                       (objc:coerce-to-selector "restartsPaneResized:")
                       "NSViewFrameDidChangeNotification" pane)
          (layout-restarts-panel controller)
          (scroll-to-end (listener-view listener))
          pane)))))

(defun hide-restarts-panel (&optional (listener *listener*))
  "Take the pane away, if there is one, and give the transcript the window
back.  Main thread only.  Idempotent."
  (let ((pane (and listener (listener-restarts-panel listener)))
        (controller (and listener
                         (getf (listener-retained listener) :restarts-controller))))
    (when (and pane (cffi:pointerp pane) (not (cffi:null-pointer-p pane)))
      (when controller
        (objc:invoke (notification-center) "removeObserver:name:object:"
                     (objc:objc-object-pointer controller)
                     "NSViewFrameDidChangeNotification" pane))
      ;; The keyboard may be in the value field, which is about to go.
      (objc:invoke (listener-window listener) "makeFirstResponder:"
                   (listener-view listener))
      (let ((split (objc:invoke pane "superview")))
        (objc:invoke pane "removeFromSuperview")
        (when (and (cffi:pointerp split) (not (cffi:null-pointer-p split)))
          (objc:invoke split "adjustSubviews")))
      (when controller
        (release-backtrace-items (getf (controller-views controller) :backtrace-items)))
      (scroll-to-end (listener-view listener)))
    (forget-restarts listener))
  t)

(defun click-restart (&optional (index 0) (listener *listener*))
  "Select restart INDEX and press Invoke, exactly as a person would.  Thread 1.

Selecting and then -performClick:ing the button drives the real path -- the
selection, the target, the action, the queued number -- rather than reaching
past it to CHOOSE-RESTART, which would prove only that CHOOSE-RESTART works.
Returns whether there was a table and a button to use."
  (let ((table (and listener (listener-restarts-table listener)))
        (button (and listener (listener-restarts-invoke listener))))
    (when (and table (cffi:pointerp table) (not (cffi:null-pointer-p table))
               button (cffi:pointerp button) (not (cffi:null-pointer-p button)))
      (select-restart-row table index)
      (objc:invoke button "performClick:" nil)
      t)))

;;; Escape, from the listener window itself.
;;;
;;; These are methods on the TEXT VIEW but they live here, with the rest of the
;;; panel's behaviour.
;;;
;;; Both selectors, and the second is the one that does the work.  Escape is
;;; NSResponder's -cancelOperation: in most controls, which is why that one is
;;; here at all -- but inside an NSTextView the standard key bindings send
;;; Escape to -complete:, the word-completion action.  Overriding only the
;;; conventional one would have looked right and done nothing.
;;;
;;; Neither changes anything unless a restarts panel is up: with no panel they
;;; both go to super, so completion still behaves as it always did.

(define-listener-method ("cancelOperation:" :void)
    ((sender objc:objc-object-pointer))
  (unless (cancel-to-top-level)
    (objc:invoke (objc:current-super) "cancelOperation:" sender)))

(define-listener-method ("complete:" :void)
    ((sender objc:objc-object-pointer))
  (unless (cancel-to-top-level)
    (objc:invoke (objc:current-super) "complete:" sender)))

;;; ⌘0 to ⌘9, from the listener window, while the pane is up.  The pane does
;;; not take the keyboard -- the prompt keeps it, so a number can be typed
;;; there -- so without these its rows were out of reach of the keyboard
;;; altogether.  A key equivalent reaches the key window's views
;;; before the menu bar, and none of the menus uses a digit.

(defconstant +ns-event-modifier-command+ (ash 1 20))
(defconstant +ns-event-modifier-shift+ (ash 1 17))

(defun restart-for-key-equivalent (listener event)
  "The row ⌘-digit EVENT names, if the panel is up and has that many rows."
  (when (restarts-panel-visible-p listener)
    (let* ((flags (objc:invoke event "modifierFlags"))
           (held (logand flags (logior +ns-event-modifier-command+
                                       +ns-event-modifier-shift+
                                       +ns-event-modifier-control+
                                       +ns-event-modifier-option+)))
           (keys (objc:ns-string-to-string
                  (objc:invoke event "charactersIgnoringModifiers")))
           (index (and (= held +ns-event-modifier-command+)
                       (= 1 (length keys))
                       (digit-char-p (char keys 0))))
           (count (restarts-table-row-count listener)))
      (and index count (< index count) index))))

(define-listener-method ("performKeyEquivalent:" objc:objc-bool)
    ((event objc:objc-object-pointer))
  (let ((index (restart-for-key-equivalent *listener* event)))
    (if index
        (progn (activate-restart index *listener*) t)
        (objc:invoke-bool (objc:current-super) "performKeyEquivalent:" event))))

(defun click-cancel (&optional (listener *listener*))
  "Press Cancel, exactly as a person would.  Thread 1.

Found among the panel's subviews by title, because unlike Invoke it is not
worth a slot on the listener just so a test can reach it."
  (let ((panel (and listener (listener-restarts-panel listener))))
    (when (and panel (cffi:pointerp panel) (not (cffi:null-pointer-p panel)))
      (let* ((subviews (objc:invoke panel "subviews"))
             (count (objc:invoke subviews "count"))
             (button-class (objc:coerce-to-objc-class "NSButton")))
        (loop for i from 0 below count
              for view = (objc:invoke subviews "objectAtIndex:" i)
              when (and (objc:invoke-bool view "isKindOfClass:" button-class)
                        (string= "Cancel"
                                 (objc:ns-string-to-string
                                  (objc:invoke view "title"))))
                do (objc:invoke view "performClick:" nil)
                   (return t))))))

(defun restarts-table-row-count (&optional (listener *listener*))
  "How many rows the table believes it has.  Thread 1.

Asked from outside so that CI can check the data source was actually consulted:
a table that renders blank still answers this, and a table whose delegate was
never found answers zero."
  (let ((table (and listener (listener-restarts-table listener))))
    (when (and table (cffi:pointerp table) (not (cffi:null-pointer-p table)))
      (objc:invoke table "numberOfRows"))))

(defun restarts-panel-visible-p (&optional (listener *listener*))
  (let ((panel (and listener (listener-restarts-panel listener))))
    (and panel (cffi:pointerp panel) (not (cffi:null-pointer-p panel))
         (not (cffi:null-pointer-p (objc:invoke panel "window"))))))
