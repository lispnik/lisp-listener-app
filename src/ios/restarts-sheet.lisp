;;;; src/ios/restarts-sheet.lisp -- the restarts as a sheet with a table.
;;;;
;;;; iOS's half of src/restarts.lisp, which explains the design.  Where the Mac
;;;; puts up a floating NSPanel with an NSTableView, this is a UIViewController
;;;; presented as a sheet, holding a UITableView of the same titles the
;;;; transcript numbers, and a Cancel button which -- as on the Mac -- takes the
;;;; restart back to the top level rather than merely closing the sheet.
;;;;
;;;; A sheet rather than a UIAlertController action sheet, which this was first:
;;;; an alert is sized by its content and there is no supported way to ask it
;;;; for more room, so a couple of restarts came up as a stub at the bottom of
;;;; the screen.  A UISheetPresentationController takes DETENTS, so the height
;;;; is ours: it opens at the medium one, half the screen, and can be dragged up
;;;; to full height when the list is long.
;;;;
;;;; A tap does what a button on the Mac does: it TYPES the restart's number,
;;;; through CHOOSE-RESTART, because the restart belongs to the listener thread.
;;;; The sheet has no room for the backtrace; the transcript has it.
;;;;
;;;; The table's data source is the RESTARTS-CONTROLLER that src/restarts.lisp
;;;; already keeps per listener -- its TITLES slot is what a data source is for
;;;; -- so the methods below are the UIKit counterparts of the NSTableView ones
;;;; in src/macos/restarts-panel.lisp.

(in-package #:lisp-listener)

(defparameter *sheet-row-height* 64d0
  "Two lines of report and the number and name under them.")
(defparameter *sheet-margin* 16d0)
(defparameter *sheet-header-height* 52d0)
(defparameter *sheet-button-height* 44d0)
(defparameter *sheet-title-font-size* 17d0)
(defparameter *sheet-row-font-size* 15d0)
(defparameter *sheet-heading-font-size* 13d0)
(defparameter *sheet-frame-row-height* 28d0)

;;; The table's data source and delegate --------------------------------------
;;;
;;; NSInteger is (:SIGNED :LONG-LONG); see src/macos/restarts-panel.lisp.

(objc:define-objc-method ("tableView:numberOfRowsInSection:" (:signed :long-long))
    ((self restarts-controller)
     (table objc:objc-object-pointer)
     (section (:signed :long-long)))
  (declare (ignorable table))
  (handler-case (if (zerop section)
                    (length (controller-titles self))
                    (length (getf (controller-views self) :frames)))
    (error (condition) (note "numberOfRowsInSection: ~a" condition) 0)))

;;; Two sections: the restarts, which are what the sheet is for, and under them
;;; the frames -- the other half of what a debugger shows, and all the
;;; transcript no longer prints while the sheet is up.  ECL keeps only the
;;; function of each frame, so that is all there is to show.
(objc:define-objc-method ("numberOfSectionsInTableView:" (:signed :long-long))
    ((self restarts-controller) (table objc:objc-object-pointer))
  (declare (ignorable table))
  (handler-case (if (getf (controller-views self) :frames) 2 1)
    (error (condition) (note "numberOfSectionsInTableView: ~a" condition) 1)))

(objc:define-objc-method ("tableView:titleForHeaderInSection:" objc:objc-object-pointer)
    ((self restarts-controller) (table objc:objc-object-pointer)
     (section (:signed :long-long)))
  (declare (ignorable table))
  ;; Autoreleased: the caller does not own what a Lisp method returns.
  (handler-case (objc:autorelease
                 (objc:invoke (objc:invoke "NSString" "alloc") "initWithString:"
                              (if (zerop section) "Restarts" "Backtrace")))
    (error (condition) (note "titleForHeaderInSection: ~a" condition)
      (cffi:null-pointer))))

(objc:define-objc-method ("tableView:willSelectRowAtIndexPath:" objc:objc-object-pointer)
    ((self restarts-controller) (table objc:objc-object-pointer)
     (index-path objc:objc-object-pointer))
  (declare (ignorable table))
  ;; A frame is not a choice: only the restarts can be selected.
  (if (zerop (objc:invoke index-path "section")) index-path (cffi:null-pointer)))

(objc:define-objc-method ("tableView:cellForRowAtIndexPath:" objc:objc-object-pointer)
    ((self restarts-controller)
     (table objc:objc-object-pointer)
     (index-path objc:objc-object-pointer))
  (declare (ignorable table))
  (handler-case
      (let* ((row (objc:invoke index-path "row"))
             (titles (controller-titles self))
             (frames (getf (controller-views self) :frames)))
        (if (zerop (objc:invoke index-path "section"))
            (let ((restart (and (>= row 0) (< row (length titles)) (nth row titles))))
              (if restart (make-restart-cell restart) (make-blank-cell)))
            (let ((frame (and (>= row 0) (< row (length frames)) (nth row frames))))
              (if frame (make-frame-cell frame) (make-blank-cell)))))
    (error (condition)
      (note "cellForRowAtIndexPath: ~a" condition)
      (make-blank-cell))))

(objc:define-objc-method ("tableView:didSelectRowAtIndexPath:" :void)
    ((self restarts-controller)
     (table objc:objc-object-pointer)
     (index-path objc:objc-object-pointer))
  (declare (ignorable table))
  (handler-case
      (let ((*listener* (or (controller-listener self) *listener*)))
        (activate-restart (objc:invoke index-path "row")))
    (error (condition) (note "didSelectRowAtIndexPath: ~a" condition))))

(defun show-sheet-backtrace (listener)
  "Take the sheet to its full height and scroll to the frames.  Thread 1."
  (let ((controller (listener-restarts-panel listener))
        (table (listener-restarts-table listener)))
    (when (and controller table (not (cffi:null-pointer-p controller)))
      (let ((sheet (objc:invoke controller "sheetPresentationController")))
        (unless (cffi:null-pointer-p sheet)
          (objc:invoke sheet "setSelectedDetentIdentifier:"
                       (%ns-string-constant
                        "UISheetPresentationControllerDetentIdentifierLarge"))))
      (when (> (objc:invoke table "numberOfSections") 1)
        (objc:invoke table "scrollToRowAtIndexPath:atScrollPosition:animated:"
                     (objc:invoke "NSIndexPath" "indexPathForRow:inSection:" 0 1)
                     1 t))                  ; UITableViewScrollPositionTop
      t)))

(objc:define-objc-method ("tableView:heightForRowAtIndexPath:" :double)
    ((self restarts-controller) (table objc:objc-object-pointer)
     (index-path objc:objc-object-pointer))
  (declare (ignorable table))
  ;; A frame is one short line; a restart is a report over its number and name.
  (handler-case (if (zerop (objc:invoke index-path "section"))
                    *sheet-row-height*
                    *sheet-frame-row-height*)
    (error () *sheet-row-height*)))

(defun make-blank-cell ()
  "An empty cell, AUTORELEASED: what the data source answers for a row it no
longer has.

Never nil.  A table asks for a cell by a row count it took earlier, and a
sheet on its way out is still a table on screen: on an iPad the focus engine
walks it during the dismissal, after the restarts have been withdrawn, and a
nil cell there is an assertion in UITableView that takes the app down."
  (objc:autorelease (objc:invoke (objc:invoke "UITableViewCell" "alloc")
                                 "initWithStyle:reuseIdentifier:" 0 "blank")))

(defun make-frame-cell (frame)
  "One frame, AUTORELEASED: its line, small, grey and not selectable."
  (let* ((cell (objc:invoke (objc:invoke "UITableViewCell" "alloc")
                            "initWithStyle:reuseIdentifier:" 0 "frame"))
         (label (objc:invoke cell "textLabel")))
    (objc:invoke label "setText:" (backtrace-frame-line frame))
    (objc:invoke label "setFont:" (uikit:mono-font *sheet-heading-font-size*))
    (objc:invoke label "setTextColor:" (objc:invoke "UIColor" "secondaryLabelColor"))
    (objc:invoke cell "setSelectionStyle:" 0)   ; UITableViewCellSelectionStyleNone
    (objc:autorelease cell)))

(defun make-restart-cell (row)
  "One row, AUTORELEASED: the restart's report, and under it, small and grey,
its number and name -- the Mac's three columns, stacked for a phone's width.
A row outside the listener, the thread's own abort, is grey throughout.

Autoreleased for the reason the Mac's row views are: an object returned from a
Lisp method is the caller's to release, UIKit asks again on every redraw, and a
+1 object here would leak one per row per reload."
  (let* ((cell (objc:invoke (objc:invoke "UITableViewCell" "alloc")
                            "initWithStyle:reuseIdentifier:"
                            3 "restart"))   ; UITableViewCellStyleSubtitle
         (label (objc:invoke cell "textLabel"))
         (detail (objc:invoke cell "detailTextLabel"))
         (secondary (objc:invoke "UIColor" "secondaryLabelColor")))
    (objc:invoke label "setText:"
                 (format nil "~a~@[ …~]" (restart-row-report row) (restart-row-asks-p row)))
    (objc:invoke label "setFont:" (uikit:font *sheet-row-font-size*))
    (when (restart-row-outside-p row)
      (objc:invoke label "setTextColor:" secondary))
    ;; Two lines, then the tail is truncated: a restart's report can be far
    ;; wider than a phone, and one row growing to five lines would push the
    ;; others off the sheet.
    (objc:invoke label "setNumberOfLines:" 2)
    (objc:invoke label "setLineBreakMode:" 4)   ; NSLineBreakByTruncatingTail
    (objc:invoke detail "setText:"
                 (format nil "~d · ~a" (restart-row-index row) (restart-row-name row)))
    (objc:invoke detail "setFont:" (uikit:mono-font (- *sheet-row-font-size* 2)))
    (objc:invoke detail "setTextColor:" secondary)
    (objc:autorelease cell)))

;;; The sheet -----------------------------------------------------------------

(defun sheet-height (count)
  "How tall the sheet wants to be for COUNT restarts, in points.

Only a wish: it is resolved against the screen, and the medium detent is what
it opens at.  The table scrolls, so a long list is not a taller sheet."
  (+ *sheet-header-height* *sheet-button-height*
     (* 3 *sheet-margin*)
     (* (max 2 count) *sheet-row-height*)))

(defun make-sheet-header (heading field &optional button)
  "A title that says the debugger level, the condition, and FIELD -- hidden
until a restart asks for a value -- stacked.  A hidden arranged view takes no
room, so the header is the same height until then."
  (let ((stack (uikit:new "UIStackView"))
        (title (uikit:new "UILabel"))
        (message (uikit:new "UILabel")))
    (objc:invoke stack "setAxis:" 1)              ; vertical
    (objc:invoke stack "setSpacing:" 2d0)
    (objc:invoke title "setText:" (heading-title heading))
    (objc:invoke title "setFont:" (uikit:bold-font *sheet-title-font-size*))
    (objc:invoke message "setText:" (heading-line heading))
    (objc:invoke message "setFont:" (uikit:mono-font *sheet-heading-font-size*))
    (objc:invoke message "setTextColor:" (objc:invoke "UIColor" "secondaryLabelColor"))
    (objc:invoke message "setNumberOfLines:" 2)
    (if button
        ;; The title, and the way to the frames at the other end of its line.
        (let ((line (uikit:new "UIStackView")))
          (objc:invoke line "setAxis:" 0)              ; horizontal
          (objc:invoke line "setDistribution:" 3)      ; equal spacing
          (objc:invoke line "addArrangedSubview:" title)
          (objc:invoke line "addArrangedSubview:" button)
          (objc:invoke stack "addArrangedSubview:" line))
        (objc:invoke stack "addArrangedSubview:" title))
    (objc:invoke stack "addArrangedSubview:" message)
    (objc:invoke stack "setCustomSpacing:afterView:" 10d0 message)
    (objc:invoke stack "addArrangedSubview:" field)
    stack))

(defun make-value-field (target)
  "Where a restart's value is typed.  Return in it sends: see
-textFieldShouldReturn:.  None of UIKit's help with prose, which would turn a
quote into a curly one and capitalise the first symbol."
  (let ((field (uikit:new "UITextField")))
    (objc:invoke field "setBorderStyle:" 3)             ; UITextBorderStyleRoundedRect
    (objc:invoke field "setFont:" (uikit:mono-font *sheet-row-font-size*))
    (objc:invoke field "setAutocorrectionType:" 1)      ; No
    (objc:invoke field "setAutocapitalizationType:" 0)  ; None
    (objc:invoke field "setSmartQuotesType:" +ui-text-smart-no+)
    (objc:invoke field "setSmartDashesType:" +ui-text-smart-no+)
    (objc:invoke field "setReturnKeyType:" 9)           ; UIReturnKeyDone
    (objc:invoke field "setDelegate:" target)
    (objc:invoke field "setHidden:" t)
    field))

(defun request-restart-value (listener index)
  "Ask, in the sheet, for the value restart INDEX wants.  Thread 1.

As on the Mac, and for the same reason: choosing USE-VALUE used to leave the
sheet and ask in the transcript, so the choice began in one place and ended in
another.  Return sends `1 42', which the debugger reads as the restart and its
value in one line."
  (let* ((controller (getf (listener-retained listener) :restarts-controller))
         (field (and controller (getf (controller-views controller) :value-field)))
         (row (and controller (nth index (controller-titles controller)))))
    (when (and field row)
      (setf (getf (controller-views controller) :value-index) index)
      (objc:invoke field "setPlaceholder:"
                   (format nil "~a: a form, evaluated in the listener"
                           (restart-row-name row)))
      (objc:invoke field "setText:" "")
      (objc:invoke field "setHidden:" nil)
      (objc:invoke field "becomeFirstResponder")
      t)))

(defun submit-restart-value (listener)
  "Take the restart that asked, with the form in the field.  Thread 1.
An empty field sends nothing."
  (let* ((controller (getf (listener-retained listener) :restarts-controller))
         (views (and controller (controller-views controller)))
         (index (getf views :value-index))
         (field (getf views :value-field))
         (text (and index field
                    (string-trim '(#\Space #\Tab #\Newline)
                                 (or (ignore-errors
                                      (objc:ns-string-to-string (objc:invoke field "text")))
                                     "")))))
    (when (and text (plusp (length text)))
      (objc:invoke field "resignFirstResponder")
      (let ((*listener* listener))
        (choose-restart index text))
      t)))

(objc:define-objc-method ("textFieldShouldReturn:" objc:objc-bool)
    ((self restarts-controller) (field objc:objc-object-pointer))
  (declare (ignorable field))
  (handler-case
      (progn (submit-restart-value (or (controller-listener self) *listener*))
             nil)
    (error (condition) (note "textFieldShouldReturn: ~a" condition) nil)))

(defun configure-sheet-detents (controller count)
  "Open at half the screen, and let it be dragged to full height.

-sheetPresentationController is iOS 15; on anything older this is NIL and the
sheet comes up at whatever the system chooses, which is still a sheet."
  (let ((sheet (objc:invoke controller "sheetPresentationController")))
    (when (and sheet (not (cffi:null-pointer-p sheet)))
      (let ((medium (objc:invoke "UISheetPresentationControllerDetent" "mediumDetent"))
            (large (objc:invoke "UISheetPresentationControllerDetent" "largeDetent"))
            (detents (objc:invoke "NSMutableArray" "array")))
        (objc:invoke detents "addObject:" medium)
        (objc:invoke detents "addObject:" large)
        (objc:invoke sheet "setDetents:" detents)
        (objc:invoke sheet "setPrefersGrabberVisible:" t)
        ;; A long list opens at full height instead, so that what is on offer
        ;; is on screen rather than behind a scroll.
        (when (> (sheet-height count) 520d0)
          (objc:invoke sheet "setSelectedDetentIdentifier:" "com.apple.UIKit.large")))))
  controller)

(defun build-restarts-sheet (listener heading titles cancel-index &optional frames)
  "The sheet's controller, filled in.  Main thread only.

Takes finished strings rather than the restarts themselves: see RESTART-TITLES
for why they cannot be printed here."
  (let* ((controller (objc:invoke (objc:invoke "UIViewController" "alloc") "init"))
         (root (objc:invoke controller "view"))
         (data-source (getf (listener-retained listener) :restarts-controller))
         (target (and data-source (objc:objc-object-pointer data-source)))
         (field (make-value-field target))
         ;; The frames are the table's second section, below the fold at the
         ;; height the sheet opens at; this is the way to them.
         (to-frames (and frames (uikit:system-button "Backtrace")))
         (header (make-sheet-header heading field to-frames))
         (table (uikit:new "UITableView"))
         (cancel (uikit:system-button "Cancel")))
    (when data-source
      (setf (controller-titles data-source) titles
            (controller-cancel-index data-source) cancel-index
            (controller-views data-source) (list :value-field field :value-index nil
                                                 :frames frames)))
    (objc:invoke root "setBackgroundColor:"
                 (objc:invoke "UIColor" "systemBackgroundColor"))
    (objc:invoke table "setDataSource:" target)
    (objc:invoke table "setDelegate:" target)
    (objc:invoke table "setRowHeight:" *sheet-row-height*)
    (objc:invoke table "setAllowsMultipleSelection:" nil)
    (objc:invoke (objc:invoke cancel "titleLabel") "setFont:"
                 (uikit:font *sheet-title-font-size*))
    (when to-frames
      (uikit:on-tap to-frames
                    (lambda (sender)
                      (declare (ignore sender))
                      (show-sheet-backtrace listener))))
    (uikit:on-tap cancel
                  (lambda (sender)
                    (declare (ignore sender))
                    (let ((*listener* listener))
                      (unless (cancel-to-top-level listener)
                        (hide-restarts-panel listener)))))
    (dolist (view (list header table cancel))
      (objc:invoke root "addSubview:" view))
    (let ((safe (objc:invoke root "safeAreaLayoutGuide")))
      (uikit:pin header "topAnchor" root "topAnchor" *sheet-margin*)
      (uikit:pin header "leadingAnchor" root "leadingAnchor" *sheet-margin*)
      (uikit:pin header "trailingAnchor" root "trailingAnchor" (- *sheet-margin*))
      (uikit:pin table "topAnchor" header "bottomAnchor" *sheet-margin*)
      (uikit:pin table "leadingAnchor" root "leadingAnchor")
      (uikit:pin table "trailingAnchor" root "trailingAnchor")
      (uikit:pin table "bottomAnchor" cancel "topAnchor" (- *sheet-margin*))
      (uikit:fix cancel "heightAnchor" *sheet-button-height*)
      (uikit:pin cancel "leadingAnchor" root "leadingAnchor" *sheet-margin*)
      (uikit:pin cancel "trailingAnchor" root "trailingAnchor" (- *sheet-margin*))
      (uikit:pin cancel "bottomAnchor" safe "bottomAnchor" (- *sheet-margin*)))
    (setf (listener-restarts-table listener) table
          (listener-restarts-invoke listener) cancel)
    (configure-sheet-detents controller (length titles))
    controller))

(defun show-restarts-panel (listener heading backtrace titles cancel-index)
  "Present TITLES, and the frames in BACKTRACE, as a sheet under HEADING.
Thread 1."
  (hide-restarts-panel listener)
  (let ((controller (build-restarts-sheet listener heading titles cancel-index
                                          backtrace)))
    ;; The +1 from -alloc is the listener's, until HIDE-RESTARTS-PANEL.
    (setf (listener-restarts-panel listener) controller)
    (present-sheet listener controller)
    controller))

(defun presenting-controller (listener)
  "The controller to present from: whatever is on top, which is the listener
view's window's root unless something is already up.

UIKit presents from the top of the stack only -- asked to present from a
controller that is already presenting, it logs a warning and does nothing.  So
an error in a form that had just drawn, with the canvas's sheet up, put no
restarts on screen at all.  A controller on its way out does not count."
  (let* ((window (objc:invoke (listener-view listener) "window"))
         (controller (objc:invoke window "rootViewController")))
    (loop for presented = (objc:invoke controller "presentedViewController")
          while (and (live-pointer-p presented)
                     (not (objc:invoke-bool presented "isBeingDismissed")))
          do (setf controller presented))
    controller))

;;; Putting a sheet up, and taking one down --------------------------------------
;;;
;;; UIKit will do neither while a transition is in flight, and says so with a
;;; warning in the log and not with a result:
;;;
;;;   - a dismissal asked for while the sheet is still arriving is dropped;
;;;   - a presentation asked for from a controller in mid-transition is put
;;;     off, and one asked for over a sheet that is about to go, goes with it;
;;;   - and -dismissViewController... sent to a sheet that has another on top
;;;     of it dismisses the one on top, and not the sheet it was sent to.
;;;
;;; Each of those left a sheet on screen that the program had already
;;; forgotten, with nothing left to take it down: the Try list, opened as the
;;; restarts went, stayed for good.  So both are ASKED AGAIN, every 0.15 s,
;;; until they can be done: a sheet is presented once whatever is leaving has
;;; left, and dismissed -- through its presenter, so that it is the one that
;;; goes -- once it has arrived and stopped moving.  Hiding a sheet that has
;;; not been presented yet cancels the presenting.  Every sheet here comes
;;; and goes this way.  -performSelector:withObject:afterDelay: retains the
;;; controller meanwhile, so the caller's own reference can go at once.

(defparameter *sheet-dismiss-tries* 14
  "How many times a sheet that is not there to dismiss is looked for again.")

(defparameter *sheet-present-tries* 40
  "How many times a sheet waits for the way to be clear.")

(defvar *sheet-dismissals* '()
  "(ADDRESS TRIES-LEFT ANIMATED) for each sheet waiting to go.  Thread 1.")

(defvar *sheet-presentations* '()
  "(ADDRESS TRIES-LEFT ANIMATED) for each sheet waiting to come.  Thread 1.")

(defun sheet-entry (controller table)
  (assoc (cffi:pointer-address controller) table))

(defun in-transition-p (controller)
  (live-pointer-p (objc:invoke controller "transitionCoordinator")))

(defun settled-presenter (view)
  "The controller a sheet can be presented from NOW, in VIEW's window: the top
of what is presented -- or NIL while anything there is arriving, leaving, or
waiting to be told to leave."
  (let* ((window (objc:invoke view "window"))
         (controller (and (live-pointer-p window)
                          (objc:invoke window "rootViewController"))))
    (loop
      (when (or (not (live-pointer-p controller)) (in-transition-p controller))
        (return nil))
      (let ((presented (objc:invoke controller "presentedViewController")))
        (cond ((not (live-pointer-p presented)) (return controller))
              ((or (objc:invoke-bool presented "isBeingDismissed")
                   (sheet-entry presented *sheet-dismissals*))
               (return nil))
              (t (setf controller presented)))))))

(defun cancel-sheet-dismissal (controller)
  "Stop waiting to dismiss CONTROLLER: it is wanted after all.  For a sheet
whose controller is kept and presented again -- the canvas's -- where a
dismissal still pending would take down the sheet just put back up."
  (when (live-pointer-p controller)
    (setf *sheet-dismissals*
          (remove (cffi:pointer-address controller) *sheet-dismissals* :key #'first)))
  t)

(defun cancel-sheet-presentation (controller)
  "Stop waiting to present CONTROLLER.  True if it was waiting."
  (when (live-pointer-p controller)
    (let ((entry (sheet-entry controller *sheet-presentations*)))
      (when entry
        (setf *sheet-presentations* (remove entry *sheet-presentations*))
        t))))

(defun sheet-later (view selector controller)
  (objc:invoke view "performSelector:withObject:afterDelay:"
               (objc:coerce-to-selector selector) controller 0.15d0))

(defun continue-sheet-presentation (view controller)
  (let ((entry (sheet-entry controller *sheet-presentations*)))
    (when entry
      (flet ((done () (setf *sheet-presentations* (remove entry *sheet-presentations*))))
        (let ((presenter (settled-presenter view)))
          (cond (presenter
                 (done)
                 (handler-case
                     (objc:invoke presenter "presentViewController:animated:completion:"
                                  controller (third entry) nil)
                   (error (condition) (note "presenting a sheet: ~a" condition))))
                ((plusp (decf (second entry))) (sheet-later view "listenerPresentSheet:" controller))
                (t (note "a sheet was never presented: the way was never clear")
                   (done))))))))

(defun present-sheet (listener controller &optional (animated t))
  "Present CONTROLLER as a sheet over LISTENER's window -- now, or as soon as
nothing there is in the way."
  (let ((view (listener-view listener)))
    (when (and (live-pointer-p view) (live-pointer-p controller))
      (cancel-sheet-dismissal controller)
      (cancel-sheet-presentation controller)
      (push (list (cffi:pointer-address controller) *sheet-present-tries* animated)
            *sheet-presentations*)
      (continue-sheet-presentation view controller)
      t)))

(defun continue-sheet-dismissal (view controller)
  "One look at CONTROLLER: dismiss it if it can be, look again shortly if it
may yet be, and give up when it has had its tries or was cancelled."
  (let ((entry (sheet-entry controller *sheet-dismissals*)))
    (when entry
      (flet ((done () (setf *sheet-dismissals* (remove entry *sheet-dismissals*))))
        (let ((presenter (objc:invoke controller "presentingViewController")))
          (cond ((objc:invoke-bool controller "isBeingDismissed") (done))
                ;; A transition in flight has a coordinator.  Not
                ;; -isBeingPresented, which is true only inside the appearance
                ;; callbacks and NO in the middle of the animation itself.
                ((in-transition-p controller) (sheet-later view "listenerDismissSheet:" controller))
                ((live-pointer-p presenter)
                 ;; Through the presenter: sent to the sheet itself, this
                 ;; dismisses whatever the sheet has presented instead.
                 (objc:invoke presenter "dismissViewControllerAnimated:completion:"
                              (third entry) nil)
                 (done))
                ;; Not there.  Never presented, or put off by UIKit: wait and see.
                ((plusp (decf (second entry))) (sheet-later view "listenerDismissSheet:" controller))
                (t (done))))))))

(defun dismiss-sheet-when-settled (view controller &optional (animated t))
  "Dismiss CONTROLLER, a sheet -- now, or as soon as it has arrived and stopped
moving; and if it was still waiting to be presented, do not present it.  VIEW
is a listener's view, to be called back on."
  (when (and (live-pointer-p view) (live-pointer-p controller))
    (cancel-sheet-dismissal controller)
    (unless (and (cancel-sheet-presentation controller)
                 (not (live-pointer-p (objc:invoke controller "presentingViewController"))))
      (push (list (cffi:pointer-address controller) *sheet-dismiss-tries* animated)
            *sheet-dismissals*)
      (continue-sheet-dismissal view controller))
    t))

(define-listener-method ("listenerDismissSheet:" :void)
    ((controller objc:objc-object-pointer))
  (continue-sheet-dismissal pointer controller))

(define-listener-method ("listenerPresentSheet:" :void)
    ((controller objc:objc-object-pointer))
  (continue-sheet-presentation pointer controller))

(defun hide-restarts-panel (&optional (listener *listener*))
  "Dismiss the sheet if it is up, and forget it.  Thread 1.  Idempotent.

A tap leaves the sheet on screen -- unlike an alert, which dismisses itself --
so this is what takes it down, whether the restart was chosen in the table or
by typing its number at the prompt."
  (let ((controller (and listener (listener-restarts-panel listener))))
    (when (and controller (cffi:pointerp controller)
               (not (cffi:null-pointer-p controller)))
      (dismiss-sheet-when-settled (listener-view listener) controller)
      (objc:release controller))
    (forget-restarts listener))
  t)

(defun restarts-panel-visible-p (&optional (listener *listener*))
  (let ((controller (and listener (listener-restarts-panel listener))))
    (and controller (cffi:pointerp controller)
         (not (cffi:null-pointer-p controller))
         (let ((presenter (objc:invoke controller "presentingViewController")))
           (and presenter (not (cffi:null-pointer-p presenter))))
         t)))

(defun restarts-table-row-count (&optional (listener *listener*))
  "How many rows the table believes it has.  Thread 1.

Asked from outside so that a test can check the data source was consulted: a
table that renders blank still answers this, and one whose data source was
never found answers zero."
  (let ((table (and listener (listener-restarts-table listener))))
    (when (and table (cffi:pointerp table) (not (cffi:null-pointer-p table)))
      (objc:invoke table "numberOfRowsInSection:" 0))))
