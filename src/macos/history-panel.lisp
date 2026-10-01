;;;; src/macos/history-panel.lisp -- the history as a panel with a search field.
;;;;
;;;; The Mac's half of src/history-search.lisp: an NSPanel holding an
;;;; NSSearchField above an NSTableView.  Typing in the field narrows the list
;;;; as you type; double-clicking a row, or pressing Return, puts that form in
;;;; the input region ready to edit; Escape closes.
;;;;
;;;; A SHEET on the listener's own window, as an Open or Save panel is.  As a
;;;; floating panel it sat over whichever window was in front -- with two
;;;; listeners, over the wrong one -- and did not move with its own; the
;;;; debugger was docked for the same reason.  A sheet is modal to its window
;;;; only, which is right for a picker, and leaves every other listener alone.
;;;;
;;;; It takes the keyboard, unlike the debugger pane -- there is a search field
;;;; in it, and a search field nobody can type into is furniture -- and the
;;;; listener's text view gets it back when the sheet ends.

(in-package #:lisp-listener)


(defparameter *history-panel-width* 620d0)
(defparameter *history-panel-height* 400d0)
(defparameter *history-panel-margin* 14d0)
(defparameter *history-search-height* 24d0)
(defparameter *history-row-height* 18d0)
(defparameter *history-row-font-size* 11d0)

;;; The table's data source and delegate.
;;;
;;; NSInteger is (:SIGNED :LONG-LONG); see src/macos/restarts-panel.lisp.

(objc:define-objc-method ("numberOfRowsInTableView:" (:signed :long-long))
    ((self history-controller) (table objc:objc-object-pointer))
  (declare (ignorable table))
  (handler-case (length (history-controller-filtered self))
    (error (condition) (note "history numberOfRows: ~a" condition) 0)))

(objc:define-objc-method ("tableView:viewForTableColumn:row:" objc:objc-object-pointer)
    ((self history-controller)
     (table objc:objc-object-pointer)
     (column objc:objc-object-pointer)
     (row (:signed :long-long)))
  (declare (ignorable table column))
  (handler-case (make-history-row-view (or (history-row self row) ""))
    (error (condition)
      (note "history viewForTableColumn: ~a" condition)
      (cffi:null-pointer))))

(objc:define-objc-method ("historyChooseRow:" :void)
    ((self history-controller) (sender objc:objc-object-pointer))
  (declare (ignorable sender))
  (handler-case
      (let* ((listener (history-controller-listener self))
             (table (and listener (listener-history-table listener))))
        (when (and table (cffi:pointerp table) (not (cffi:null-pointer-p table)))
          (let ((*listener* (or listener *listener*)))
            (choose-history-row listener (objc:invoke table "selectedRow")))))
    (error (condition) (note "historyChooseRow: ~a" condition))))

(objc:define-objc-method ("historyDismiss:" :void)
    ((self history-controller) (sender objc:objc-object-pointer))
  (declare (ignorable sender))
  (handler-case (hide-history-popup (history-controller-listener self))
    (error (condition) (note "historyDismiss: ~a" condition))))

(defun focus-history-list (listener)
  "Give the list the keyboard, with a row selected: the way down from the
search field.  True when there was a row to go to.  Thread 1.

Once there the list keeps the keys a list has -- the arrows move the
selection, and ↑ on the top row goes back to the field -- and the sheet's
buttons keep theirs: Return is Insert, Escape is Cancel."
  (let ((panel (listener-history-panel listener))
        (table (listener-history-table listener)))
    (when (and panel table (not (cffi:null-pointer-p table))
               (plusp (objc:invoke table "numberOfRows")))
      (when (minusp (objc:invoke table "selectedRow"))
        (select-restart-row table 0))
      (objc:invoke table "scrollRowToVisible:" (objc:invoke table "selectedRow"))
      (objc:invoke panel "makeFirstResponder:" table)
      t)))

(defun focus-history-search (listener)
  "Give the search field the keyboard back: the way up from the top of the
list.  True when there was a field to go to.  Thread 1."
  (let ((panel (listener-history-panel listener)))
    (when (live-pointer-p panel)
      (let ((field (objc:invoke panel "initialFirstResponder")))
        (when (live-pointer-p field)
          (objc:invoke panel "makeFirstResponder:" field)
          t)))))

;;; The list is a table of its own class for one key.  ↑ on the top row has
;;; nowhere to go in a table, and here it goes back up into the search field:
;;; the way in was ↓, and the way out should be the key opposite.  A table
;;; takes its arrows in -keyDown: itself and offers them to no delegate, so
;;; this is the one place the key can be seen; every other key is super's.
(objc:define-objc-class history-table-view ()
  ()
  (:objc-class-name "LispListenerHistoryTable")
  (:objc-superclass-name "NSTableView"))

(defun history-table-leaves-upward-p (table event)
  "Whether EVENT, a key pressed in TABLE, is ↑ with the top row selected (or
none), so that the keyboard should go back to the search field."
  (let ((characters (objc:ns-string-to-string
                     (objc:invoke event "charactersIgnoringModifiers"))))
    (and (plusp (length characters))
         (eq :up (canvas-key-for-character (char characters 0)))
         (<= (objc:invoke table "selectedRow") 0))))

(objc:define-objc-method ("keyDown:" :void)
    ((self history-table-view pointer) (event objc:objc-object-pointer))
  (unless (handler-case
              (and (history-table-leaves-upward-p pointer event)
                   (focus-history-search
                    (find pointer *listeners* :key #'listener-history-table
                                              :test #'same-objc-object-p)))
            (error (condition) (note "history keyDown: ~a" condition) nil))
    (objc:invoke (objc:current-super) "keyDown:" event)))

;;; ↓ in the search field goes down into the list.  The field editor offers
;;; every key it would act on to the field's delegate first, as a selector:
;;; answering true for moveDown: is what stops it putting the caret at the end
;;; of the query instead.
(objc:define-objc-method ("control:textView:doCommandBySelector:" objc:objc-bool)
    ((self history-controller)
     (control objc:objc-object-pointer)
     (text-view objc:objc-object-pointer)
     (command objc:sel))
  (declare (ignorable control text-view))
  (handler-case
      (and (string= "moveDown:" (objc:selector-name command))
           (focus-history-list (history-controller-listener self)))
    (error (condition) (note "history doCommandBySelector: ~a" condition) nil)))

;;; The search field's delegate: NSSearchField tells its delegate on every
;;; keystroke, which is what makes the narrowing incremental.

(objc:define-objc-method ("controlTextDidChange:" :void)
    ((self history-controller) (notification objc:objc-object-pointer))
  (handler-case
      (let* ((field (objc:invoke notification "object"))
             (query (objc:ns-string-to-string (objc:invoke field "stringValue")))
             (listener (history-controller-listener self))
             (table (and listener (listener-history-table listener))))
        (refilter-history self query)
        (when (and table (cffi:pointerp table) (not (cffi:null-pointer-p table)))
          (objc:invoke table "reloadData")
          ;; Something selected always, so Return means the obvious thing.
          (when (plusp (length (history-controller-filtered self)))
            (select-restart-row table 0))))
    (error (condition) (note "history controlTextDidChange: ~a" condition))))

;;; Building it ------------------------------------------------------------------

(defun make-history-row-view (line)
  "One row, AUTORELEASED -- AppKit asks again on every redraw; see
MAKE-ROW-VIEW in src/macos/restarts-panel.lisp."
  (let ((field (objc:invoke (objc:invoke "NSTextField" "alloc") "initWithFrame:"
                            (vector 0d0 0d0
                                    (- *history-panel-width*
                                       (* 2 *history-panel-margin*) 24d0)
                                    *history-row-height*))))
    (objc:invoke field "setStringValue:" (squeeze-whitespace line))
    (objc:invoke field "setBezeled:" nil)
    (objc:invoke field "setDrawsBackground:" nil)
    (objc:invoke field "setEditable:" nil)
    (objc:invoke field "setSelectable:" nil)
    (objc:invoke field "setFont:"
                 (objc:invoke "NSFont" "monospacedSystemFontOfSize:weight:"
                              *history-row-font-size* 0d0))
    ;; A submitted form may be several lines long; SQUEEZE-WHITESPACE has made
    ;; it one, and the tail is truncated rather than clipped mid-word.
    (objc:invoke (objc:invoke field "cell") "setLineBreakMode:" 4)
    (objc:autorelease field)))

(defun make-history-search-field (target width y)
  (let ((field (objc:invoke (objc:invoke "NSSearchField" "alloc") "initWithFrame:"
                            (vector *history-panel-margin* y
                                    (- width (* 2 *history-panel-margin*))
                                    *history-search-height*))))
    (objc:invoke field "setDelegate:" target)
    (objc:invoke field "setPlaceholderString:" "Search history")
    ;; Return in the field chooses the selected row rather than doing nothing.
    (objc:invoke field "setTarget:" target)
    (objc:invoke field "setAction:" (objc:coerce-to-selector "historyChooseRow:"))
    field))

(defun make-history-table (listener target width y height)
  (let* ((frame (vector *history-panel-margin* y
                        (- width (* 2 *history-panel-margin*)) height))
         (scroll (objc:invoke (objc:invoke "NSScrollView" "alloc")
                              "initWithFrame:" frame))
         ;; The Lisp object is held by the listener for as long as the table
         ;; is; the next list replaces it.
         (object (make-instance 'history-table-view
                                :init-function
                                (lambda (pointer &rest initargs)
                                  (declare (ignore initargs))
                                  (objc:invoke pointer "initWithFrame:" frame))
                                :allow-other-keys t))
         (table (objc:objc-object-pointer object))
         (column (objc:invoke (objc:invoke "NSTableColumn" "alloc")
                              "initWithIdentifier:" "history")))
    (setf (getf (listener-retained listener) :history-table) object)
    (objc:invoke column "setWidth:" (- width (* 2 *history-panel-margin*) 24d0))
    (objc:invoke table "addTableColumn:" column)
    (objc:release column)
    (objc:invoke table "setHeaderView:" nil)
    (objc:invoke table "setRowHeight:" *history-row-height*)
    (objc:invoke table "setUsesAlternatingRowBackgroundColors:" t)
    (objc:invoke table "setAllowsMultipleSelection:" nil)
    (objc:invoke table "setDataSource:" target)
    (objc:invoke table "setDelegate:" target)
    (objc:invoke table "setTarget:" target)
    (objc:invoke table "setDoubleAction:"
                 (objc:coerce-to-selector "historyChooseRow:"))
    (objc:invoke scroll "setHasVerticalScroller:" t)
    (objc:invoke scroll "setBorderType:" 2)       ; NSBezelBorder
    (objc:invoke scroll "setDocumentView:" table)
    (objc:invoke table "reloadData")
    (select-restart-row table 0)
    (setf (listener-history-table listener) table)
    scroll))

(defun build-history-panel (listener)
  "The panel: a search field, the list, and Insert and Cancel.  Thread 1."
  (let* ((width *history-panel-width*)
         (height *history-panel-height*)
         (controller (listener-history-controller listener))
         (target (objc:objc-object-pointer controller))
         (panel (objc:invoke (objc:invoke "NSPanel" "alloc")
                             "initWithContentRect:styleMask:backing:defer:"
                             (vector 0d0 0d0 width height)
                             +ns-window-style-titled+
                             +ns-backing-store-buffered+ nil))
         (content (objc:invoke panel "contentView")))
    (objc:invoke panel "setReleasedWhenClosed:" nil)
    (objc:invoke panel "setTitle:" "History")
    ;; Laid out downwards from the top, as an NSView's origin is bottom left.
    (let* ((search-y (- height *history-panel-margin* *history-search-height*))
           (buttons-y *history-panel-margin*)
           (table-y (+ buttons-y *push-button-height* *panel-gap*))
           (table-height (- search-y table-y *panel-gap*)))
      (let ((field (make-history-search-field target width search-y)))
        (objc:invoke content "addSubview:" field)
        (objc:invoke panel "setInitialFirstResponder:" field)
        (objc:release field))
      (let ((table (make-history-table listener target width table-y table-height)))
        (objc:invoke content "addSubview:" table)
        (objc:release table))
      (let* ((insert-x (- width *history-panel-margin* *push-button-width*))
             (cancel-x (- insert-x *push-button-width* 4d0))
             (cancel (make-push-button "Cancel" "historyDismiss:" target
                                       cancel-x buttons-y (string #\Escape)))
             (insert (make-push-button "Insert" "historyChooseRow:" target
                                       insert-x buttons-y (string #\Return))))
        (objc:invoke content "addSubview:" cancel)
        (objc:invoke content "addSubview:" insert)
        (objc:release cancel)
        (objc:release insert)))
    panel))

;;; Showing and hiding ------------------------------------------------------------

(defun show-history-popup (listener)
  "Put the list on screen, with the keyboard in its search field.  Thread 1."
  (hide-history-popup listener)
  (let ((panel (build-history-panel listener))
        (window (listener-window listener)))
    (setf (listener-history-panel listener) panel)
    ;; No completion handler: HIDE-HISTORY-POPUP ends it, on every path.
    (objc:invoke window "beginSheet:completionHandler:" panel (cffi:null-pointer))
    ;; Key, unlike the debugger pane: there is a search field to type into.
    (objc:invoke panel "makeFirstResponder:"
                 (objc:invoke panel "initialFirstResponder"))
    panel))

(defun hide-history-popup (&optional (listener *listener*))
  "Take the list down, and give the listener window the keyboard back.
Thread 1.  Idempotent."
  (let ((panel (and listener (listener-history-panel listener))))
    (when (and panel (cffi:pointerp panel) (not (cffi:null-pointer-p panel)))
      (let ((parent (objc:invoke panel "sheetParent")))
        (if (cffi:null-pointer-p parent)
            (objc:invoke panel "orderOut:" nil)
            (objc:invoke parent "endSheet:" panel)))
      (let ((window (listener-window listener)))
        (when (and window (cffi:pointerp window) (not (cffi:null-pointer-p window)))
          (objc:invoke window "makeKeyAndOrderFront:" nil)
          (objc:invoke window "makeFirstResponder:" (listener-view listener)))))
    (forget-history-popup listener))
  t)

(defun history-popup-visible-p (&optional (listener *listener*))
  (let ((panel (and listener (listener-history-panel listener))))
    (and panel (cffi:pointerp panel) (not (cffi:null-pointer-p panel))
         (objc:invoke-bool panel "isVisible")
         t)))

(defun history-row-count (&optional (listener *listener*))
  "How many rows the table believes it has.  Thread 1; asked by the tests, so
that a list which draws blank cannot pass."
  (let ((table (and listener (listener-history-table listener))))
    (when (and table (cffi:pointerp table) (not (cffi:null-pointer-p table)))
      (objc:invoke table "numberOfRows"))))

(defun type-history-query (query &optional (listener *listener*))
  "Type QUERY into the search field, exactly as a person would.  Thread 1.

Straight at the field and then through -controlTextDidChange:, which is the
notification AppKit sends for a keystroke -- so the narrowing under test is the
real path and not a second one written for the test."
  (let* ((panel (and listener (listener-history-panel listener)))
         (controller (listener-history-controller listener)))
    (when (and panel (cffi:pointerp panel) (not (cffi:null-pointer-p panel))
               controller)
      (let* ((content (objc:invoke panel "contentView"))
             (subviews (objc:invoke content "subviews"))
             (count (objc:invoke subviews "count"))
             (field-class (objc:coerce-to-objc-class "NSSearchField")))
        (loop for index from 0 below count
              for view = (objc:invoke subviews "objectAtIndex:" index)
              when (objc:invoke-bool view "isKindOfClass:" field-class)
                do (objc:invoke view "setStringValue:" query)
                   (objc:invoke (objc:objc-object-pointer controller)
                                "controlTextDidChange:"
                                (make-text-change-notification view))
                   (return query))))))

(defun make-text-change-notification (object)
  "An NSNotification whose -object is OBJECT, autoreleased.
What AppKit hands a control's delegate; the handler reads only that."
  (objc:invoke "NSNotification" "notificationWithName:object:"
               "NSControlTextDidChangeNotification" object))
