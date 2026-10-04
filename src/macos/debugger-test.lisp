;;;; src/macos/debugger-test.lisp -- the docked debugger, driven and checked.
;;;;
;;;; LISP_LISTENER_DEBUGGER_TEST=<directory> makes the application drive the
;;;; debugger pane through everything a person does with it, check each step,
;;;; write a few pictures to the directory, and leave with 0 only if every check
;;;; held.  CI runs it on both architectures.
;;;;
;;;; Why it exists: the headless test cannot reach any of this -- it is all
;;;; AppKit -- and the screenshot run only photographs the pane and clicks two
;;;; buttons.  Every bug in the pane's first versions was found by a driver like
;;;; this one and by nothing else: an empty table, a column that stopped short,
;;;; frames cut off at a hundred points, a ⌘-key that never arrived.
;;;;
;;;; Keys are sent the way AppKit sends a key equivalent -- to the window's
;;;; -performKeyEquivalent:, then the main menu's -- and not through
;;;; -[NSApplication sendEvent:].  A process started from a shell or a CI runner
;;;; is not the active application, has no key window, and sendEvent: then
;;;; delivers the key to nothing at all.  For the same reason the checks ask
;;;; which view is first responder IN the window, never whether it is key.
;;;;
;;;; Runs on THREAD 1, in an NSTimer callback, pumping between steps; see
;;;; src/macos/screenshot.lisp, whose helpers it uses.

(in-package #:lisp-listener)

(defvar *debugger-test-failures* 0)

;;; Defined in app.lisp, which loads after this file.
(declaim (ftype function new-listener))

(defun check-step (ok format-control &rest arguments)
  (unless ok (incf *debugger-test-failures*))
  (note "debugger-test: ~:[FAIL~;ok  ~]  ~?" ok format-control arguments)
  ok)

(defun key-equivalent-event (window characters &optional (flags +ns-event-modifier-command+))
  (objc:invoke "NSEvent"
               "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"
               10 (vector 0d0 0d0) flags 0d0 (objc:invoke window "windowNumber")
               (cffi:null-pointer) characters characters nil 0))

(defun press-key-equivalent (window characters &optional (flags +ns-event-modifier-command+))
  "What -[NSApplication sendEvent:] does with a key equivalent when there is a
key window: the window's views first, then the menu bar.  True if taken."
  (let ((event (key-equivalent-event window characters flags)))
    (prog1 (or (objc:invoke-bool window "performKeyEquivalent:" event)
               (objc:invoke-bool (objc:invoke (objc.runloop:shared-application) "mainMenu")
                                 "performKeyEquivalent:" event))
      (pump 0.1d0))))

(defun pane-views (listener)
  (controller-views (getf (listener-retained listener) :restarts-controller)))

(defun first-responder-is-p (window view)
  "Whether VIEW has the keyboard in WINDOW -- VIEW itself, or the field editor
editing it, which is what AppKit makes first responder for a text field."
  (let ((responder (objc:invoke window "firstResponder")))
    (or (cffi:pointer-eq responder view)
        (and (objc:invoke-bool responder "respondsToSelector:"
                               (objc:coerce-to-selector "delegate"))
             (cffi:pointer-eq (objc:invoke responder "delegate") view)))))

(defun raise-error (listener form)
  "Submit FORM and wait for the pane.  True if it came."
  (type-and-submit listener form)
  (prog1 (wait-for (lambda () (restarts-panel-visible-p listener)) :timeout 10)
    (pump-for 0.3d0)))

(defun back-at-top-p (listener)
  (and (wait-for (lambda () (and (waiting-at-top-level-p listener)
                                 (not (restarts-panel-visible-p listener))))
                 :timeout 10)
       t))

(defun press-top-level-row (listener)
  (press-key-equivalent (listener-window listener)
                        (format nil "~d" (toplevel-restart-row listener))))

(defun subview-count (view)
  (objc:invoke (objc:invoke view "subviews") "count"))

(defun debugger-test-docking (listener)
  (let* ((window (listener-window listener))
         (view (listener-view listener))
         (split (listener-split-view listener)))
    (check-step split "the window's content is a split view")
    (check-step (and split (= 1 (subview-count split))) "holding only the transcript")
    (submit-and-wait listener
                     "(defun deep (n) (declare (optimize (debug 2))) (let ((k (* n 3))) (+ k (car n))))"
                     "DEEP")
    (check-step (raise-error listener "(deep 7)") "an error opens the pane")
    (let ((pane (listener-restarts-panel listener)))
      (check-step (and pane (cffi:pointer-eq (objc:invoke pane "window") window))
                  "in the listener window")
      (check-step (= 2 (subview-count split)) "under the transcript"))
    (check-step (first-responder-is-p window view) "and the keyboard stays at the prompt")
    (let* ((text (transcript-text listener))
           (from (search "(deep 7)" text :from-end t)))
      (check-step (and from (search "Restarts: 0 ABORT" text :start2 from))
                  "the transcript gives the restarts in a line, the pane has them in full")
      (check-step (and from (not (search "Backtrace:" text :start2 from)))
                  "and leaves the frames to the pane"))
    (check-step (eql (objc:invoke (listener-restarts-table listener) "selectedRow")
                     (toplevel-restart-row listener))
                "the selected row is the way back to the top level")))

(defun debugger-test-frames (listener directory)
  (let* ((views (pane-views listener))
         (items (getf views :backtrace-items))
         (outline (objc:invoke (getf views :backtrace) "documentView"))
         (frames (backtrace-items-frames items))
         (deep (position-if (lambda (frame) (search "DEEP" (backtrace-frame-line frame)))
                            frames))
         (rows (objc:invoke outline "numberOfRows")))
    (check-step deep "the frames include DEEP: ~s" (mapcar #'backtrace-frame-line frames))
    (check-step (not (some (lambda (frame) (search "SIMPLE-EVAL" (backtrace-frame-line frame)))
                           frames))
                "and not the evaluator frames under it")
    (when deep
      (objc:invoke outline "expandItem:" (aref (backtrace-items-roots items) deep))
      (pump-for 0.2d0)
      (check-step (member "N = 7" (backtrace-frame-locals (nth deep frames)) :test #'string=)
                  "DEEP's frame carries N = 7")
      (check-step (> (objc:invoke outline "numberOfRows") rows)
                  "and opening it shows its locals as rows"))
    (let ((column (objc:invoke (objc:invoke outline "tableColumns") "objectAtIndex:" 0)))
      (check-step (> (objc:invoke column "width") (* 0.9d0 (aref (objc:invoke outline "frame") 2)))
                  "the frames' column fills the outline, so frames are not cut short"))
    (capture (listener-window listener) directory "debugger-frames.png")))

(defun debugger-test-keyboard (listener)
  (let* ((window (listener-window listener))
         (view (listener-view listener))
         (views (pane-views listener))
         (outline (objc:invoke (getf views :backtrace) "documentView")))
    (check-step (not (objc:invoke-bool (listener-restarts-table listener) "acceptsFirstResponder"))
                "the restarts refuse the keyboard, so a click leaves it at the prompt")
    (check-step (not (objc:invoke-bool outline "acceptsFirstResponder")) "and so do the frames")
    (check-step (not (press-key-equivalent window (string #\Return) 0))
                "Return is nobody's key equivalent in the listener window")
    (let ((before (length (transcript-text listener))))
      (replace-pending-input (listener-view-object listener) view "(+ 20 22)")
      (objc:invoke view "insertNewline:" (cffi:null-pointer))
      (check-step (wait-for (lambda () (search "42" (transcript-text listener) :start2 before))
                            :timeout 5)
                  "so a form typed at [1] with the pane up is evaluated")
      (pump-for 0.2d0)
      (check-step (restarts-panel-visible-p listener) "and the pane stays"))
    ;; The ⌘-digits are the view's; every other ⌘-key must still reach the
    ;; menus.  Asked of each in turn: the menu's Clear Transcript acts on the
    ;; KEY window's listener, and there is no key window here to see it act.
    (let ((event (key-equivalent-event window "k")))
      (check-step (not (objc:invoke-bool window "performKeyEquivalent:" event))
                  "⌘K is declined by the listener window")
      (check-step (objc:invoke-bool (objc:invoke (objc.runloop:shared-application) "mainMenu")
                                    "performKeyEquivalent:" event)
                  "and taken by the menu bar"))))

(defun debugger-test-divider (listener)
  (let* ((split (listener-split-view listener))
         (table (getf (pane-views listener) :table))
         (before (aref (objc:invoke table "frame") 3)))
    (objc:invoke split "setPosition:ofDividerAtIndex:"
                 (* 0.2d0 (aref (objc:invoke split "bounds") 3)) 0)
    (pump-for 0.3d0)
    (check-step (> (aref (objc:invoke table "frame") 3) before)
                "moving the divider lays the pane out again (~,0f -> ~,0f)"
                before (aref (objc:invoke table "frame") 3))
    (let ((before (length (transcript-text listener))))
      (press-top-level-row listener)
      (check-step (back-at-top-p listener) "⌘ and the top-level row's number return to the top")
      (check-step (search (format nil "] CL-USER> ~d~%; Aborted." (or (toplevel-restart-row listener) 0))
                          (transcript-text listener) :start2 (max 0 (- before 40)))
                  "and the transcript shows the number, as if typed"))
    (check-step (= 1 (subview-count split)) "the transcript has the window again")))

(defun debugger-test-value (listener directory)
  (let* ((window (listener-window listener))
         (view (listener-view listener)))
    (check-step (raise-error listener "(+ 1 *no-such-variable*)") "an unbound variable")
    (check-step (= 1 (length (backtrace-items-frames
                               (getf (pane-views listener) :backtrace-items))))
                "shows one frame, not the evaluator three times over")
    (let* ((table (getf (pane-views listener) :table))
           (before (aref (objc:invoke table "frame") 3)))
      (press-key-equivalent window "1")
      (check-step (>= (aref (objc:invoke table "frame") 3) (- before 1d0))
                  "the value field does not cost the list any room (~,0f -> ~,0f)"
                  before (aref (objc:invoke table "frame") 3)))
    (let* ((views (pane-views listener))
           (field (getf views :value-field)))
      (check-step (eql 1 (getf views :value-index)) "⌘1, USE-VALUE, asks for its value in the pane")
      (check-step (first-responder-is-p window field) "and the field has the keyboard")
      (capture window directory "debugger-value.png")
      ;; Escape, as the field editor sends it to the field's delegate.
      (objc:invoke (objc:objc-object-pointer (getf (listener-retained listener)
                                                   :restarts-controller))
                   "control:textView:doCommandBySelector:"
                   field (objc:invoke window "firstResponder")
                   (objc:coerce-to-selector "cancelOperation:"))
      (pump-for 0.2d0)
      (check-step (null (getf (pane-views listener) :value-index))
                  "Escape in the field puts the question away")
      (check-step (restarts-panel-visible-p listener) "and nothing else")
      (check-step (first-responder-is-p window view) "and gives the keyboard back"))
    (press-key-equivalent window "1")
    (objc:invoke (getf (pane-views listener) :value-field) "setStringValue:" "41")
    (objc:invoke (listener-restarts-invoke listener) "performClick:" nil)
    (check-step (back-at-top-p listener) "Invoke sends the value and the pane goes")
    (check-step (search (format nil "] CL-USER> 1 41~%42") (transcript-text listener))
                "as `1 41' at the prompt: (+ 1 41) = 42, with no blank line")
    (check-step (not (member "1 41" (view-history (listener-view-object listener))
                             :test #'string=))
                "and not into the history")
    (check-step (first-responder-is-p window view) "with the keyboard at the prompt")
    ;; ⌘-digits reach the rows from the field too: the key equivalent goes to
    ;; every view in the window, whichever has the keyboard.
    (raise-error listener "(+ 1 *no-such-variable*)")
    (press-key-equivalent window "1")
    (check-step (first-responder-is-p window (getf (pane-views listener) :value-field))
                "with the field asking again")
    (press-top-level-row listener)
    (check-step (back-at-top-p listener) "⌘ and a number still choose a row")))

(defun debugger-test-pending-input (listener)
  (let ((view (listener-view-object listener))
        (pointer (listener-view listener)))
    (raise-error listener "(car 7)")
    (replace-pending-input view pointer "(list 1")
    (press-top-level-row listener)
    (back-at-top-p listener)
    (pump-for 0.2d0)
    (check-step (string= "(list 1" (pending-input view pointer))
                "a half-typed line survives a restart chosen by key: ~s"
                (pending-input view pointer))
    (replace-pending-input view pointer "")))

(defun debugger-test-line-start (listener)
  "C-a, Home and ⌘←: the start of the line is after the prompt."
  (let* ((view (listener-view-object listener))
         (pointer (listener-view listener)))
    (back-at-top-p listener)
    (replace-pending-input view pointer "(+ 1 2)")
    (flet ((caret () (- (caret-index pointer) (view-input-start view)))
           (to-end () (objc:invoke pointer "setSelectedRange:"
                                   (cons (transcript-length pointer) 0))))
      (dolist (selector '("moveToBeginningOfParagraph:" "moveToBeginningOfLine:"
                          "moveToLeftEndOfLine:"))
        (to-end)
        (objc:invoke pointer selector (cffi:null-pointer))
        (check-step (zerop (caret))
                    "-~a puts the caret after the prompt, not before it" selector))
      (to-end)
      (objc:invoke pointer "moveToBeginningOfParagraphAndModifySelection:" (cffi:null-pointer))
      (check-step (equal (objc:invoke pointer "selectedRange")
                         (cons (view-input-start view) 7))
                  "with Shift it selects back to the prompt, and no further")
      ;; A second line starts at the margin, and that is the text view's own.
      (replace-pending-input view pointer (format nil "(list 1~%      2)"))
      (to-end)
      (objc:invoke pointer "moveToBeginningOfParagraph:" (cffi:null-pointer))
      (check-step (= 8 (caret)) "on a second line of input it is that line's start")
      ;; And up in the transcript nothing of ours is in the way.
      (objc:invoke pointer "setSelectedRange:" (cons 3 0))
      (objc:invoke pointer "moveToBeginningOfParagraph:" (cffi:null-pointer))
      (check-step (zerop (caret-index pointer))
                  "in the transcript above, the start of the line is the margin"))
    (replace-pending-input view pointer "")
    (objc:invoke pointer "setSelectedRange:" (cons (transcript-length pointer) 0))))

(defun debugger-test-levels (listener)
  (raise-error listener "(+ 1 *no-such-variable*)")
  (type-and-submit listener "(error \"second\")")
  (wait-for (lambda () (search "[2]" (last-line (transcript-text listener)))) :timeout 10)
  (pump-for 0.5d0)
  (let* ((views (pane-views listener))
         (lines (mapcar #'backtrace-frame-line
                        (backtrace-items-frames (getf views :backtrace-items)))))
    (check-step (and (some (lambda (line) (search "second" line)) lines)
                     (notany (lambda (line) (search "NO-SUCH-VARIABLE" line)) lines))
                "level 2's frames are the second error's: ~s" lines)
    (check-step (search "Level 2" (objc:ns-string-to-string
                                   (objc:invoke (getf views :type) "stringValue")))
                "and the pane says Level 2"))
  (press-top-level-row listener)
  (check-step (back-at-top-p listener) "and ⌘ goes all the way back"))

(defun debugger-test-history (listener)
  "The history list: a sheet on its own window, narrowed, and a choice put back."
  (let ((window (listener-window listener))
        (view (listener-view-object listener))
        (pointer (listener-view listener)))
    (open-history-popup listener)
    (pump-for 0.3d0)
    (let ((panel (listener-history-panel listener)))
      (check-step (and panel (cffi:pointer-eq (objc:invoke panel "sheetParent") window))
                  "⌘R's list is a sheet on the listener's own window")
      ;; Narrowed, not to a number: the history is kept between launches, so
      ;; this machine's earlier runs are in it too.
      (let ((all (history-row-count listener)))
        (type-history-query "defun deep" listener)
        (pump 0.1d0)
        (check-step (< 0 (history-row-count listener) all)
                    "typing narrows it (~d rows -> ~d)" all (history-row-count listener)))
      ;; ↓ from the search field, as the field editor sends it to the
      ;; field's delegate: the list takes the keyboard.
      (let ((field (objc:invoke panel "firstResponder")))
        (objc:invoke (objc:objc-object-pointer (listener-history-controller listener))
                     "control:textView:doCommandBySelector:"
                     field field (objc:coerce-to-selector "moveDown:"))
        (pump 0.1d0)
        (check-step (cffi:pointer-eq (objc:invoke panel "firstResponder")
                                     (listener-history-table listener))
                    "↓ in the search field moves the keyboard to the list")
        (check-step (>= (objc:invoke (listener-history-table listener) "selectedRow") 0)
                    "with a row selected")
        ;; ↑ on the top row, through the table's own -keyDown:, goes back.
        (let ((table (listener-history-table listener)))
          (select-restart-row table 0)
          (objc:invoke table "keyDown:"
                       (key-equivalent-event panel (string (code-char #xF700)) 0))
          (pump 0.1d0)
          (check-step (not (cffi:pointer-eq (objc:invoke panel "firstResponder") table))
                      "↑ on the top row takes the keyboard back up")
          (check-step (first-responder-is-p panel (objc:invoke panel "initialFirstResponder"))
                      "to the search field")
          ;; And lower down it is the table's own key still, which is super's
          ;; -keyDown:.  The whole list, to have a second row to be on.
          (type-history-query "" listener)
          (pump 0.1d0)
          (objc:invoke panel "makeFirstResponder:" table)
          (select-restart-row table 1)
          (objc:invoke table "keyDown:"
                       (key-equivalent-event panel (string (code-char #xF700)) 0))
          (pump 0.1d0)
          (check-step (and (cffi:pointer-eq (objc:invoke panel "firstResponder") table)
                           (= 0 (objc:invoke table "selectedRow")))
                      "↑ on a lower row moves the selection, as in any list")
          (type-history-query "defun deep" listener)
          (pump 0.1d0)))
      (choose-history-row listener 0)
      (pump-for 0.3d0)
      (check-step (search "(defun deep" (pending-input view pointer))
                  "choosing it puts it at the prompt, unsubmitted")
      (check-step (not (history-popup-visible-p listener)) "and the sheet goes")
      (check-step (first-responder-is-p window pointer) "with the keyboard at the prompt"))
    (replace-pending-input view pointer "")))

(defun debugger-test-two-listeners (first)
  "A second listener, as New Listener opens one: its debugger, its keys and its
history are its own, and closing it leaves the first as it was."
  (let* ((second (new-listener :title "Second Listener"))
         (first-window (listener-window first))
         (second-window (listener-window second)))
    (check-step (wait-for (lambda () (waiting-at-top-level-p second)) :timeout 20)
                "New Listener opens a second window, at its own prompt")
    (check-step (raise-error second "(car 'second)") "an error in the second")
    (check-step (cffi:pointer-eq (objc:invoke (listener-restarts-panel second) "window")
                                 second-window)
                "docks its pane in the second window")
    (check-step (= 1 (subview-count (listener-split-view first)))
                "and not in the first, which is still just its transcript")
    (check-step (not (press-key-equivalent first-window "0"))
                "⌘0 in the first window is not the second's to take")
    (check-step (restarts-panel-visible-p second) "so the second is still in its debugger")
    (open-history-popup second)
    (pump-for 0.3d0)
    (check-step (cffi:pointer-eq (objc:invoke (listener-history-panel second) "sheetParent")
                                 second-window)
                "⌘R in the second window is a sheet on the second window")
    (hide-history-popup second)
    (press-key-equivalent second-window "0")
    (check-step (back-at-top-p second) "⌘0 in its own window returns it to its top level")
    (objc:invoke second-window "close")
    (pump-for 0.5d0)
    (check-step (not (member second *listeners*)) "closing it ends that listener")
    (check-step (and (submit-and-wait first "(+ 2 3)" "5") t)
                "and the first, untouched, still evaluates")))

;;; A stand-in for AppKit's dragging info: all -performDragOperation: asks of
;;; it is its pasteboard.  So a drop is driven through the view's own IMP.
(objc:define-objc-class test-drag ()
  ((pasteboard :initform nil :accessor test-drag-pasteboard))
  (:objc-class-name "LispListenerTestDrag"))

(objc:define-objc-method ("draggingPasteboard" objc:objc-object-pointer)
    ((self test-drag))
  (test-drag-pasteboard self))

(defun call-with-test-drag (paths function)
  "Call FUNCTION with a stand-in drag carrying PATHS, as the Finder's would."
  (let ((pasteboard (objc:invoke "NSPasteboard" "pasteboardWithUniqueName"))
        (urls (objc:invoke "NSMutableArray" "array"))
        (drag (make-instance 'test-drag)))
    (objc:invoke pasteboard "clearContents")
    (dolist (path paths)
      (objc:invoke urls "addObject:" (objc:invoke "NSURL" "fileURLWithPath:" path)))
    (objc:invoke pasteboard "writeObjects:" urls)
    (setf (test-drag-pasteboard drag) pasteboard)
    (unwind-protect (funcall function (objc:objc-object-pointer drag))
      (objc:invoke pasteboard "releaseGlobally"))))

(defun drop-files (listener paths)
  "Drop PATHS on LISTENER's view, as the Finder would.  Answers what the view's
-performDragOperation: answered.

For files the view takes itself.  One it leaves to NSTextView must not come
this way: super asks a real drag for a dozen things this stand-in does not
have, and every run logged the exception the first of them raised."
  (call-with-test-drag
   paths
   (lambda (drag)
     (objc:invoke-bool (listener-view listener) "performDragOperation:" drag))))

(defun dropped-paths (paths)
  "What the view reads off a drag of PATHS, and which of those it would load:
the decision -performDragOperation: makes, without making the drop."
  (call-with-test-drag
   paths
   (lambda (drag)
     (let ((read (dragged-file-paths drag)))
       (values read (remove-if-not #'loadable-file-p read))))))

(defun debugger-test-files (listener directory)
  "File > Open..., a drop, and Save Transcript...: the panels are AppKit's, so
what is checked is everything either side of them."
  (check-step (and (menu-item-present-p "File" "Open…")
                   (menu-item-present-p "File" "Save Transcript…"))
              "the File menu has Open… and Save Transcript…, wired to the controller")
  (let* ((dir (uiop:ensure-directory-pathname (merge-pathnames "files/" directory)))
         (lisp (namestring (merge-pathnames "dropped.lisp" dir)))
         (text (namestring (merge-pathnames "dropped.txt" dir)))
         (saved (namestring (merge-pathnames "transcript.txt" dir))))
    (ensure-directories-exist dir)
    (with-open-file (out lisp :direction :output :if-exists :supersede)
      (write-string "(defun cl-user::dropped-in () :dropped)" out))
    (with-open-file (out text :direction :output :if-exists :supersede)
      (write-string "words" out))
    (check-step (drop-files listener (list lisp)) "a Lisp file dropped on the window is taken")
    (check-step (wait-for (lambda () (search (load-form lisp) (transcript-text listener)))
                          :timeout 10)
                "and loaded, with the load typed at the prompt")
    (back-at-top-p listener)
    (check-step (submit-and-wait listener "(cl-user::dropped-in)" ":DROPPED")
                "what it defined is there to call")
    (multiple-value-bind (read loadable) (dropped-paths (list text))
      (check-step (and (= 1 (length read)) (search "dropped.txt" (first read))
                       (null loadable))
                  "a text file dropped is read off the drag and left to the text view"))
    (save-transcript listener saved)
    (let ((written (uiop:read-file-string saved :external-format :utf-8)))
      (check-step (and (search "CL-USER>" written) (search (load-form lisp) written))
                  "Save Transcript… writes the transcript, the load included"))))

(defun canvas-mouse-test-event (type x y)
  "A mouse event at (X, Y) in the canvas window's coordinates, as AppKit would
deliver one.  TYPE is an NSEventType: 1 down, 2 up, 5 moved, 6 dragged."
  (objc:invoke "NSEvent"
               "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"
               type (vector x y) 0 0d0
               (objc:invoke *canvas-window* "windowNumber")
               (cffi:null-pointer) 0 1 1.0))

(defun press-menu-item (menu-title item-title)
  "Choose ITEM-TITLE from MENU-TITLE: its action is sent to its target, with
the item as the sender, which is what a click comes to.  True if it was sent.

Not -performActionForItemAtIndex:, which declines a disabled item -- and here
every item is one.  This process is not the active application, and once the
menu bar has been handed a key equivalent in that state its items all answer NO
to -isEnabled, while ⌘K goes on being taken.  Measured; it is the driver's
condition and not the application's."
  (let* ((application (objc.runloop:shared-application))
         (holder (objc:invoke (objc:invoke application "mainMenu")
                              "itemWithTitle:" menu-title))
         (submenu (and (live-pointer-p holder) (objc:invoke holder "submenu")))
         (item (and (live-pointer-p submenu)
                    (objc:invoke submenu "itemWithTitle:" item-title))))
    (when (live-pointer-p item)
      (prog1 (objc:invoke-bool application "sendAction:to:from:"
                               (objc:invoke item "action") (objc:invoke item "target") item)
        (pump 0.1d0)))))

(defun debugger-test-canvas (listener directory)
  "The canvas and the examples: the menu, the window, a picture, the keys."
  (check-step (and (menu-item-present-p "Examples" "Spiral")
                   (menu-item-present-p "Examples" "Snake")
                   (menu-item-present-p "Examples" "Pong"))
              "the Examples menu lists them, wired to the controller")
  (check-step (not (canvas-visible-p)) "there is no canvas until something is drawn")
  (let ((paints *canvas-paints*))
    (check-step (press-menu-item "Examples" "Spiral") "Examples > Spiral is chosen")
    (check-step (wait-for (lambda () (search "(example \"spiral\")" (transcript-text listener)))
                          :timeout 10)
                "and typed at the prompt")
    (check-step (wait-for (lambda () (and (canvas-visible-p) (> *canvas-paints* paints)))
                          :timeout 10)
                "the canvas opens and is painted")
    (back-at-top-p listener)
    (pump-for 0.3d0)
    (check-step (= 140 (length (canvas-contents))) "with the spiral's 140 lines on it"))
  (check-step (first-responder-is-p (listener-window listener) (listener-view listener))
              "the keyboard stays at the prompt")
  (let ((picture (namestring (merge-pathnames "canvas.png"
                                              (uiop:ensure-directory-pathname directory)))))
    (write-window-png *canvas-window* picture)
    (check-step (and (probe-file picture)
                     (> (with-open-file (in picture :element-type '(unsigned-byte 8))
                          (file-length in))
                        5000))
                "a picture of it is more than a blank rectangle"))
  ;; (show) is what a game calls: now the canvas has the keys.
  (submit-and-wait listener "(progn (show) :shown)" ":SHOWN")
  (check-step (wait-for (lambda () (first-responder-is-p *canvas-window* (canvas-view-pointer)))
                        :timeout 5)
              ;; Which window is KEY cannot be asked here: this process is not
              ;; the active application, and has none.
              "(show) leaves the canvas's view first responder in its window")
  (check-step (eq (current-listener) listener)
              "a menu command over the canvas still means the listener behind it")
  (loop while (canvas:key))
  (objc:invoke (canvas-view-pointer) "keyDown:"
               (key-equivalent-event *canvas-window* (string (code-char #xF702)) 0))
  (objc:invoke (canvas-view-pointer) "keyDown:"
               (key-equivalent-event *canvas-window* "q" 0))
  (check-step (and (eq (canvas:key) :left) (eql (canvas:key) #\q) (null (canvas:key)))
              "a left arrow and a q pressed in it are what (key) answers")
  ;; The mouse, as AppKit delivers it: an event to the view, in the window's
  ;; coordinates.  The middle of a 480-point canvas is the canvas's (0, 0).
  (flet ((mouse (type x y) (canvas-mouse-test-event type x y)))
    (let* ((bounds (objc:invoke (canvas-view-pointer) "bounds"))
           (cx (/ (aref bounds 2) 2)) (cy (/ (aref bounds 3) 2))
           (unit (/ (min (aref bounds 2) (aref bounds 3)) 200)))
      (objc:invoke (canvas-view-pointer) "mouseDown:" (mouse 1 cx cy))
      (multiple-value-bind (x y down) (canvas:pointer)
        (check-step (and down (< (abs x) 0.01) (< (abs y) 0.01))
                    "a press in the middle of the canvas is (pointer) at (0, 0), down"))
      (check-step (eq (canvas:key) :click) "and the key :click")
      (objc:invoke (canvas-view-pointer) "mouseDragged:"
                   (mouse 6 (+ cx (* 50 unit)) (+ cy (* 25 unit))))
      (multiple-value-bind (x y down) (canvas:pointer)
        (check-step (and down (< (abs (- x 50)) 0.01) (< (abs (- y 25)) 0.01))
                    "dragged right and up it is (50, 25): y goes up, as on the canvas"))
      (objc:invoke (canvas-view-pointer) "mouseUp:" (mouse 2 cx cy))
      (check-step (not (nth-value 2 (canvas:pointer))) "and released it is up")
      ;; Hover: no button, and (pointer) still follows.
      (check-step (= 1 (objc:invoke (objc:invoke (canvas-view-pointer) "trackingAreas") "count"))
                  "the canvas has a tracking area, which is what gets it -mouseMoved:")
      (objc:invoke (canvas-view-pointer) "mouseMoved:"
                   (mouse 5 (- cx (* 40 unit)) (- cy (* 10 unit))))
      (multiple-value-bind (x y down) (canvas:pointer)
        (check-step (and (not down) (< (abs (+ x 40)) 0.01) (< (abs (+ y 10)) 0.01))
                    "moved with no button down, (pointer) follows to (-40, -10), up"))))
  ;; Saved, from the prompt: the PNG is the view's doing, on thread 1, waited for.
  (let ((png (namestring (merge-pathnames "saved.png" (uiop:ensure-directory-pathname directory))))
        (svg (namestring (merge-pathnames "saved.svg" (uiop:ensure-directory-pathname directory)))))
    (submit-and-wait listener (format nil "(progn (save ~s) (save ~s) :saved)" png svg) ":SAVED")
    (check-step (and (file-not-empty-p png) (file-not-empty-p svg))
                "(save) writes the canvas as a PNG and as SVG"))
  (check-step (menu-item-present-p "File" "Save Canvas…")
              "the File menu has Save Canvas…")
  ;; An example at the prompt to change, rather than run.
  (type-and-submit listener "(example-edit \"hello\")")
  (check-step (wait-for (lambda ()
                          (search "(circle 0 0 60)"
                                  (pending-input (listener-view-object listener)
                                                 (listener-view listener))))
                        :timeout 10)
              "(example-edit) puts an example's source at the prompt, unsubmitted")
  ;; Emptied first: "at the top level" means a prompt with nothing after it.
  (replace-pending-input (listener-view-object listener) (listener-view listener) "")
  (back-at-top-p listener)
  (submit-and-wait listener "(progn (dotimes (i 5) (frame (dot i 0) (dot 0 i)) (wait 0.02)) :framed)"
                   ":FRAMED")
  (check-step (= 2 (length (canvas-contents))) "each frame replaces the last")
  ;; A shape that is wrong is an error where it was typed, in the debugger.
  (check-step (raise-error listener "(circle 0 0 :big)")
              "a bad argument to a shape opens the debugger")
  (press-top-level-row listener)
  (check-step (back-at-top-p listener) "and its top-level restart returns")
  ;; Closed in the middle of an animation, it stays closed until the next
  ;; form, and the close is Escape to a game; then drawing brings it back.
  (loop while (canvas:key))
  (let ((before (length (transcript-text listener))))
    (type-and-submit listener
                     "(progn (dotimes (i 30) (frame (dot i 0)) (wait 0.05)) :animated)")
    (pump-for 0.4d0)
    (check-step (canvas-visible-p) "an animation is running in the canvas")
    (objc:invoke *canvas-window* "close")
    (check-step (wait-for (lambda () (search ":ANIMATED" (transcript-text listener)
                                             :start2 before))
                          :timeout 10)
                "closed half way, the animation runs on to its end")
    (pump-for 0.2d0))
  (check-step (and (not (canvas-visible-p)) (eq (canvas:key) :escape))
              "and the canvas stays closed, with Escape for whatever reads its keys")
  (submit-and-wait listener "(progn (clear) (dot 0 0 40) :dotted)" ":DOTTED")
  (check-step (wait-for #'canvas-visible-p :timeout 5) "and drawing opens it again")
  (hide-canvas)
  (objc:invoke (listener-window listener) "makeFirstResponder:" (listener-view listener))
  (pump-for 0.2d0))

(defun transcript-point-size (listener)
  "The size of the type the transcript's first character is set in."
  (objc:invoke (objc:invoke (transcript-storage (listener-view listener))
                            "attribute:atIndex:effectiveRange:"
                            (%ns-string-constant "NSFontAttributeName") 0
                            (cffi:null-pointer))
               "pointSize"))

(defun debugger-test-settings (listener directory)
  "The Settings window and the View menu: a switch, the size of the type, and
the file they are written to."
  (check-step (and (menu-item-present-p "Lisp Listener" "Settings…")
                   (menu-item-present-p "View" "Bigger")
                   (menu-item-present-p "View" "Smaller"))
              "Settings… and the View menu's Bigger and Smaller are wired to the controller")
  (check-step (press-menu-item "Lisp Listener" "Settings…") "Settings… is chosen")
  (check-step (and (live-pointer-p *preferences-window*)
                   (objc:invoke-bool *preferences-window* "isVisible"))
              "and its window opens")
  (write-window-png *preferences-window*
                    (namestring (merge-pathnames "settings.png"
                                                 (uiop:ensure-directory-pathname directory))))
  (let ((box (preference-control :paredit)))
    (check-step (= 1 (objc:invoke box "state")) "the paredit switch shows it on")
    (objc:invoke box "performClick:" nil)
    (pump 0.1d0)
    (check-step (and (null *paredit-enabled*)
                     (null (getf (read-preferences) :paredit t)))
                "clicking it switches paredit off, and the file says so")
    (let ((view (listener-view-object listener)) (pointer (listener-view listener)))
      (replace-pending-input view pointer "")
      (objc:invoke pointer "insertText:replacementRange:" "(" (cons #x7FFFFFFFFFFFFFFF 0))
      (check-step (string= "(" (pending-input view pointer))
                  "so a paren typed now is one paren")
      (replace-pending-input view pointer ""))
    (objc:invoke box "performClick:" nil)
    (pump 0.1d0)
    (check-step *paredit-enabled* "and clicking again switches it back on"))
  (let ((before (transcript-point-size listener)))
    (check-step (press-menu-item "View" "Bigger") "View > Bigger is chosen")
    (pump 0.1d0)
    (check-step (= (transcript-point-size listener) (1+ before))
                "the transcript already there is set a point bigger (~a -> ~a)"
                before (transcript-point-size listener))
    (check-step (= (1+ before) (getf (read-preferences) :font-size 0))
                "the file has the new size")
    (let ((popup (preference-control :font-size)))
      (check-step (string= (font-size-title (1+ before))
                           (objc:ns-string-to-string (objc:invoke popup "titleOfSelectedItem")))
                  "and so does the Settings window's pop-up")
      ;; Back, through the pop-up, as a choice from it arrives.
      (objc:invoke popup "selectItemWithTitle:" (font-size-title before))
      (objc:invoke (objc:objc-object-pointer *preferences-controller*)
                   "preferenceFontSize:" popup)
      (pump 0.1d0)
      (check-step (= (transcript-point-size listener) before)
                  "choosing a size in the pop-up sets the type in it")))
  ;; Not pressed: it opens the file in another application.
  (let ((button (preference-control :init-file)))
    (check-step (and (live-pointer-p button)
                     (cffi:pointer-eq (objc:invoke button "action")
                                      (objc:coerce-to-selector "preferenceEditInitFile:")))
                "Settings has Edit init.lisp…, wired to open the file"))
  (hide-preferences-window)
  (check-step (not (objc:invoke-bool *preferences-window* "isVisible")) "Settings closes")
  ;; (download url), from a file:// URL so as to need no network, and into the
  ;; run's own directory rather than the person's Downloads.
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (source (merge-pathnames "download-source.txt" directory))
         (target (merge-pathnames "fetched.txt" directory)))
    (with-open-file (out source :direction :output :if-exists :supersede)
      (write-string "fetched, not typed" out))
    (check-step (submit-and-wait listener
                                 (format nil "(download \"file://~a\" \"~a\")"
                                         (namestring source) (namestring target))
                                 "fetched.txt")
                "(download url) answers where it put the file")
    (check-step (and (probe-file target)
                     (equal "fetched, not typed" (uiop:read-file-line target)))
                "and the file is what was at the URL")
    (check-step (submit-and-wait listener "(download \"http://example.invalid/x\")"
                                 "Only https://")
                "an address that brings nothing back says so, and what is fetched")
    (wait-for (lambda () (restarts-panel-visible-p listener)) :timeout 10)
    (pump-for 0.3d0)
    (press-top-level-row listener)
    (check-step (back-at-top-p listener) "and the top-level restart leaves it")))

(defun debugger-test-windows (listener)
  "Where the windows were: recorded, refused when out of reach, and put back."
  (let* ((window (listener-window listener))
         (frame (window-frame-list window)))
    (remember-windows)
    (check-step (equal (first (getf (read-preferences) :windows)) frame)
                "the listener's frame is written to the preferences file")
    (check-step (and (not (set-window-frame window '(-50000 -50000 760 520)))
                     (equal (window-frame-list window) frame))
                "a frame on no screen is refused, and the window stays where it is")
    (check-step (not (set-window-frame window '(10 10 5 5)))
                "and so is one too small to be a window")
    ;; Two windows remembered: the first is moved, the second opened.
    (let ((first-frame (list (+ (first frame) 30) (- (second frame) 30) 700d0 480d0))
          (second-frame (list (+ (first frame) 60) (- (second frame) 60) 640d0 440d0)))
      (setf (getf *remembered* :windows) (list first-frame second-frame))
      (check-step (eql 2 (restore-windows listener)) "two windows remembered are two restored")
      (pump-for 0.5d0)
      (check-step (equal (window-frame-list window) first-frame)
                  "the first where it was")
      (let ((second (find listener *listeners* :test-not #'eq)))
        (check-step (and second
                         (equal (window-frame-list (listener-window second)) second-frame))
                    "and a second listener opened where the second was")
        (when second
          (objc:invoke (listener-window second) "close")
          (pump-for 0.5d0)))
      (check-step (equal *listeners* (list listener)) "closing it leaves the first")
      (objc:invoke window "setFrame:display:" (coerce frame 'vector) t)
      (pump-for 0.2d0))))

(defun send-control-action (control)
  "Do what a click on CONTROL does: send its action to its target."
  (objc:invoke control "sendAction:to:"
               (objc:invoke control "action") (objc:invoke control "target")))

(defun newest-inspector-ready-p (count)
  "Whether there are COUNT inspectors and the newest has a window showing a model."
  (and (= count (length *inspectors*))
       (let ((inspector (first *inspectors*)))
         (and (inspector-model inspector)
              (live-pointer-p (inspector-part inspector :window))
              (objc:invoke-bool (inspector-part inspector :window) "isVisible")))))

(defun inspector-pane-titles (inspector)
  (mapcar (lambda (pane) (and pane (pane-model-view-title pane)))
          (model-panes (inspector-model inspector))))

(defun inspector-drawing-count (inspector pane kind)
  (let ((drawing (pane-model-drawing (pane-model-of inspector pane))))
    (and drawing (count kind (drawing-scene-ops drawing) :key #'first))))

(defun debugger-test-inspector (listener directory)
  "The inspector: its window, two views side by side, an option, walking in and
back, an edit, contributed controls, and the four ways of opening one."
  (flet ((picture (inspector name)
           (pump-for 0.3d0)
           (write-window-png (inspector-part inspector :window)
                             (namestring (merge-pathnames
                                          name (uiop:ensure-directory-pathname directory))))))
    (check-step (menu-item-present-p "Listener" "Inspect")
                "the Listener menu has Inspect, wired to the controller")
    (submit-and-wait listener
                     "(progn (defparameter *bytes* (let ((v (make-array 256 :element-type '(unsigned-byte 8)))) (dotimes (i 256 v) (setf (aref v i) (mod (* i i) 256))))) :made)"
                     ":MADE")
    (type-and-submit listener "(inspect *bytes*)")
    (check-step (wait-for (lambda () (newest-inspector-ready-p 1)) :timeout 15)
                "(inspect x) at the prompt opens an inspector's window")
    (back-at-top-p listener)
    (let* ((inspector (first *inspectors*))
           (left (inspector-pane-parts inspector 0))
           (right (inspector-pane-parts inspector 1)))
      (check-step (equal (inspector-pane-titles inspector) '("Histogram" "Hex"))
                  "a byte vector is a histogram in one pane and hex in the other")
      (check-step (and (drawing-view-scene (getf left :drawing-object))
                       (not (objc:invoke-bool (getf left :drawing) "isHidden"))
                       (objc:invoke-bool (getf left :table-scroll) "isHidden"))
                  "the histogram's pane shows a drawing and no table")
      (check-step (= 16 (objc:invoke (getf right :table) "numberOfRows"))
                  "the hex pane's table has 256 bytes in 16 rows")
      (check-step (= 3 (objc:invoke (objc:invoke (getf right :table) "tableColumns") "count"))
                  "of three columns: offset, hex, text")
      (picture inspector "inspector.png")
      ;; An option of the view, through the control made for it.
      (check-step (= 32 (inspector-drawing-count inspector 0 :rect))
                  "the histogram has its 32 bins")
      (let ((slider (first (getf left :option-controls))))
        (objc:invoke slider "setDoubleValue:" 16d0)
        (send-control-action slider)
        (check-step (wait-for (lambda () (eql 16 (inspector-drawing-count inspector 0 :rect)))
                              :timeout 10)
                    "moving its bins slider to 16 redraws it with 16"))
      ;; Another view, through the pane's pop-up.
      (objc:invoke (getf right :popup) "selectItemWithTitle:" "Elements")
      (send-control-action (getf right :popup))
      (check-step (wait-for (lambda () (equal (inspector-pane-titles inspector)
                                              '("Histogram" "Elements")))
                            :timeout 10)
                  "choosing Elements in the right pane's pop-up shows that view")
      (pump-for 0.2d0)
      (check-step (= 256 (objc:invoke (getf right :table) "numberOfRows"))
                  "a row an element")
      ;; Select a row: the object panel's field has it, and changes it.
      (select-restart-row (getf right :table) 3)
      (pump 0.1d0)
      (let ((field (inspector-part inspector :editor)))
        (check-step (and (objc:invoke-bool field "isEnabled")
                         (string= "9" (objc:ns-string-to-string
                                       (objc:invoke field "stringValue"))))
                    "selecting element 3 puts its value, 9, in the panel's field")
        (objc:invoke field "setStringValue:" "(+ 100 100)")
        (send-control-action field)
        (check-step (wait-for (lambda ()
                                (let ((row (inspector-pane-row inspector 1 3)))
                                  (and row (member "200" (row-cells row) :test #'string=))))
                              :timeout 10)
                    "a form typed there is evaluated and put at the element")
        (check-step (submit-and-wait listener "(aref *bytes* 3)" "200")
                    "and the vector itself has changed")
        (objc:invoke field "setStringValue:" "999")
        (send-control-action field)
        (check-step (wait-for (lambda ()
                                (plusp (length (objc:ns-string-to-string
                                                (objc:invoke (inspector-part inspector :message)
                                                             "stringValue")))))
                              :timeout 10)
                    "999 is refused by a byte vector, and the window says so"))
      ;; Walk into a row, and back by the path.
      (inspector-open-row inspector 1 5)
      (check-step (wait-for (lambda () (= 2 (length (model-path (inspector-model inspector)))))
                            :timeout 10)
                  "opening a row walks into its value")
      (pump-for 0.2d0)
      (check-step (equal (first (inspector-pane-titles inspector)) "Integer")
                  "which is shown in the views that apply to it")
      (let ((buttons (objc:invoke (inspector-part inspector :path-bar) "subviews")))
        (objc:invoke (objc:invoke buttons "objectAtIndex:" 0) "performClick:" nil))
      (check-step (wait-for (lambda () (= 1 (length (model-path (inspector-model inspector)))))
                            :timeout 10)
                  "and the path's first button leads back"))
    ;; A contributed view, and contributed controls: the thermal example.
    (type-and-submit listener "(example \"thermal\")")
    (check-step (wait-for (lambda () (newest-inspector-ready-p 2)) :timeout 20)
                "the thermal example opens an inspector on its plate")
    (back-at-top-p listener)
    (let* ((inspector (first *inspectors*))
           (plate (inspector-object inspector)))
      (check-step (equal (first (inspector-pane-titles inspector)) "Temperature")
                  "in the view the example contributed")
      (check-step (equal (mapcar #'control-model-label (model-controls (inspector-model inspector)))
                         '("Ambient" "Source"))
                  "with the controls it contributed in the object panel")
      (let ((slider (second (inspector-part inspector :control-views))))
        (check-step (= 90d0 (objc:invoke slider "doubleValue"))
                    "the Source slider stands at the plate's 90")
        (objc:invoke slider "setDoubleValue:" 10d0)
        (send-control-action slider)
        (check-step (wait-for (lambda () (eql 10d0 (slot-value plate 'cl-user::source))) :timeout 10)
                    "moving it changes the plate")
        (check-step (wait-for (lambda ()
                                (eql 10d0 (control-model-value
                                           (second (model-controls (inspector-model inspector))))))
                              :timeout 10)
                    "and the inspector shows it as it now is")
        (objc:invoke slider "setDoubleValue:" 95d0)
        (send-control-action slider)
        (wait-for (lambda () (eql 95d0 (slot-value plate 'cl-user::source))) :timeout 10))
      (picture inspector "inspector-thermal.png"))
    ;; The other ways in.
    (submit-and-wait listener "(list :one :two :three)" ":THREE")
    (back-at-top-p listener)
    (check-step (press-menu-item "Listener" "Inspect") "Listener > Inspect is chosen")
    (check-step (wait-for (lambda () (newest-inspector-ready-p 3)) :timeout 15)
                "and opens an inspector")
    (check-step (equal (inspector-object (first *inspectors*)) '(:one :two :three))
                "on the last value")
    (back-at-top-p listener)
    ;; A value in the transcript is a link to itself.
    (let* ((pointer (listener-view listener))
           (text (transcript-text listener))
           (at (search "(:ONE :TWO :THREE)" text))
           (link (and at (objc:invoke (transcript-storage pointer)
                                      "attribute:atIndex:effectiveRange:"
                                      (%ns-string-constant "NSLinkAttributeName")
                                      (utf-16-length (subseq text 0 (1+ at)))
                                      (cffi:null-pointer)))))
      (check-step (live-pointer-p link) "a value printed at the prompt is a link")
      (when (live-pointer-p link)
        (check-step (objc:invoke-bool pointer "textView:clickedOnLink:atIndex:" pointer link 0)
                    "a click on it is taken")
        (check-step (wait-for (lambda () (newest-inspector-ready-p 4)) :timeout 15)
                    "and opens an inspector")
        (check-step (equal (inspector-object (first *inspectors*)) '(:one :two :three))
                    "on that value")))
    ;; A local in the debugger's frames.
    (check-step (raise-error listener "(deep 7)") "an error, for its frames")
    (let* ((controller (getf (listener-retained listener) :restarts-controller))
           (items (getf (pane-views listener) :backtrace-items))
           (frame (position-if (lambda (f) (search "DEEP" (backtrace-frame-line f)))
                               (backtrace-items-frames items))))
      (check-step (and frame
                       (inspect-backtrace-item
                        controller (aref (aref (backtrace-items-children items) frame) 0)))
                  "a local of DEEP's frame can be inspected")
      (check-step (wait-for (lambda () (newest-inspector-ready-p 5)) :timeout 15)
                  "which opens an inspector")
      (check-step (eql 7 (inspector-object (first *inspectors*))) "on N, which is 7"))
    (press-top-level-row listener)
    (back-at-top-p listener)
    ;; A hash table: an entry added and an entry removed, from the object panel.
    (submit-and-wait listener
                     "(progn (defparameter *table* (make-hash-table :test 'equal)) (setf (gethash \"one\" *table*) 1) :tabled)"
                     ":TABLED")
    (type-and-submit listener "(inspect *table*)")
    (check-step (wait-for (lambda () (newest-inspector-ready-p 6)) :timeout 15)
                "an inspector on a hash table")
    (back-at-top-p listener)
    (let* ((inspector (first *inspectors*))
           (table (inspector-object inspector))
           (parts (inspector-pane-parts inspector 0)))
      (check-step (and (live-pointer-p (inspector-part inspector :add-key))
                       (live-pointer-p (inspector-part inspector :add-value)))
                  "has fields for a key and a value to add")
      (objc:invoke (inspector-part inspector :add-key) "setStringValue:" "(string-downcase \"TWO\")")
      (objc:invoke (inspector-part inspector :add-value) "setStringValue:" "(+ 1 1)")
      (objc:invoke (inspector-part inspector :add-button) "performClick:" nil)
      (check-step (wait-for (lambda () (eql 2 (gethash "two" table))) :timeout 10)
                  "Add evaluates both and puts the entry in the table")
      (check-step (wait-for (lambda ()
                              (loop for index below 8
                                    for row = (inspector-pane-row inspector 0 index)
                                    thereis (and row (equal "\"two\"" (first (row-cells row))))))
                            :timeout 10)
                  "and the table's rows show it")
      (pump-for 0.2d0)
      (flet ((row-of (label)
               (loop for index below 8
                     for row = (inspector-pane-row inspector 0 index)
                     when (and row (equal label (first (row-cells row)))) return index)))
        (select-restart-row (getf parts :table) (row-of "count"))
        (pump 0.1d0)
        (check-step (not (objc:invoke-bool (inspector-part inspector :remove-button) "isEnabled"))
                    "a row that is only a fact about the table cannot be removed")
        (select-restart-row (getf parts :table) (row-of "\"one\""))
        (pump 0.1d0)
        (check-step (objc:invoke-bool (inspector-part inspector :remove-button) "isEnabled")
                    "an entry's row can be")
        (objc:invoke (inspector-part inspector :remove-button) "performClick:" nil)
        (check-step (wait-for (lambda () (and (= 1 (hash-table-count table))
                                              (null (gethash "one" table))))
                              :timeout 10)
                    "and Remove drops its key"))
      (picture inspector "inspector-table.png"))
    ;; A grid: the cell meant is the one in the column clicked.
    (type-and-submit listener "(inspect (make-array '(2 3) :initial-element :x))")
    (check-step (wait-for (lambda () (newest-inspector-ready-p 7)) :timeout 15)
                "an inspector on a 2D array of symbols")
    (back-at-top-p listener)
    (let* ((inspector (first *inspectors*))
           (matrix (inspector-object inspector)))
      (check-step (equal (first (inspector-pane-titles inspector)) "Grid") "opens on its grid")
      ;; As a click on row 1, column 2 of the table would leave it: the first
      ;; column is the row's label, so that is the array's [1 1].
      (setf (inspector-part inspector :selection) (list 0 1 2))
      (show-inspector-selection inspector)
      (let ((field (inspector-part inspector :editor)))
        (check-step (and (objc:invoke-bool field "isEnabled")
                         (string= ":X" (objc:ns-string-to-string
                                        (objc:invoke field "stringValue")))
                         (search "[1 1]" (objc:ns-string-to-string
                                          (objc:invoke (inspector-part inspector :editor-caption)
                                                       "stringValue"))))
                    "selecting a cell puts that cell, [1 1], in the panel's field")
        (objc:invoke field "setStringValue:" ":y")
        (send-control-action field)
        (check-step (wait-for (lambda () (eq :y (aref matrix 1 1))) :timeout 10)
                    "and the field changes that cell, not the row's last")
        (check-step (eq :x (aref matrix 1 2)) "which is as it was")))
    ;; They go when asked to.
    (hide-inspectors)
    (pump-for 0.3d0)
    (check-step (null *inspectors*) "closing the windows ends the inspectors")))

(defun window-mouse-test-event (window type x y)
  "A mouse event at (X, Y) in WINDOW's coordinates.  TYPE as for
CANVAS-MOUSE-TEST-EVENT."
  (objc:invoke "NSEvent"
               "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"
               type (vector x y) 0 0d0 (objc:invoke window "windowNumber")
               (cffi:null-pointer) 0 1 1.0))

(defun inspector-table-row-of (inspector pane label)
  "The index of the row of PANE's table whose first cell is LABEL."
  (loop for index below 64
        for row = (inspector-pane-row inspector pane index)
        when (and row (equal label (first (row-cells row)))) return index))

(defun views-sheet-row-of (inspector title)
  (position title (inspector-part inspector :sheet-rows)
            :key (lambda (row) (getf row :title)) :test #'string=))

(defun debugger-test-inspector-more (listener directory)
  "What the inspector grew next: a readout under the pointer, the sheet of
every view, inserting and removing in the middle, and Objective-C objects --
a pointer vouched for, an array walked into, a window's picture and controls."
  (flet ((picture (window name)
           (pump-for 0.3d0)
           (write-window-png window
                             (namestring (merge-pathnames
                                          name (uiop:ensure-directory-pathname directory))))))
    ;; A readout: the pointer over the histogram says which bin it is on.
    (type-and-submit listener "(inspect *bytes*)")
    (check-step (wait-for (lambda () (newest-inspector-ready-p 1)) :timeout 15)
                "an inspector on the byte vector again")
    (back-at-top-p listener)
    (let* ((inspector (first *inspectors*))
           (window (inspector-part inspector :window))
           (left (inspector-pane-parts inspector 0))
           (drawing (getf left :drawing))
           (object (getf left :drawing-object))
           (bounds (objc:invoke drawing "bounds"))
           (centre (objc:invoke drawing "convertPoint:toView:"
                                (vector (/ (aref bounds 2) 2) (/ (aref bounds 3) 2)) nil)))
      (objc:invoke drawing "mouseMoved:"
                   (window-mouse-test-event window 5 (aref centre 0) (aref centre 1)))
      (check-step (wait-for (lambda () (drawing-view-readout object)) :timeout 10)
                  "the pointer over the histogram is answered with a readout")
      (check-step (let ((readout (drawing-view-readout object)))
                    (and readout (search "bytes" (first readout))
                         (< (abs (second readout)) 1) (< (abs (third readout)) 1)))
                  "which names the bin under the middle of the drawing: ~a"
                  (first (drawing-view-readout object)))
      (picture window "inspector-readout.png")
      (objc:invoke drawing "mouseExited:"
                   (window-mouse-test-event window 5 0d0 0d0))
      (check-step (null (drawing-view-readout object)) "and goes when the pointer leaves")
      ;; Every view there is.
      (check-step (live-pointer-p (inspector-part inspector :all-views-button))
                  "the object panel has an All Views button")
      (objc:invoke (inspector-part inspector :all-views-button) "performClick:" nil)
      (pump-for 0.6d0)
      (check-step (views-sheet-open-p inspector) "which puts up a sheet")
      (let ((table (inspector-part inspector :sheet-table))
            (rows (inspector-part inspector :sheet-rows)))
        (check-step (= (length *views*) (objc:invoke table "numberOfRows"))
                    "listing every view there is, ~d of them" (length *views*))
        (check-step (and (getf (first rows) :applies)
                         (not (getf (first (last rows)) :applies)))
                    "those that apply first")
        (let ((heat (views-sheet-row-of inspector "Heat map"))
              (elements (views-sheet-row-of inspector "Elements")))
          (check-step (and heat (search "Needs" (views-sheet-cell (nth heat rows) 4)))
                      "a view that does not apply says what it needs: ~a"
                      (and heat (views-sheet-cell (nth heat rows) 4)))
          (select-restart-row table heat)
          (pump 0.1d0)
          (check-step (not (objc:invoke-bool (inspector-part inspector :sheet-right) "isEnabled"))
                      "and cannot be put in a pane")
          (picture (inspector-part inspector :sheet) "inspector-views.png")
          (select-restart-row table elements)
          (pump 0.1d0)
          (check-step (objc:invoke-bool (inspector-part inspector :sheet-right) "isEnabled")
                      "one that applies can")
          (objc:invoke (inspector-part inspector :sheet-right) "performClick:" nil)
          (check-step (wait-for (lambda () (equal (inspector-pane-titles inspector)
                                                  '("Histogram" "Elements")))
                                :timeout 10)
                      "Show in Right Pane shows it there")
          (pump-for 0.5d0)
          (check-step (not (views-sheet-open-p inspector)) "and takes the sheet down"))))
    ;; In the middle of a list.
    (type-and-submit listener "(inspect (list :a :b :c))")
    (check-step (wait-for (lambda () (newest-inspector-ready-p 2)) :timeout 15)
                "an inspector on a list")
    (back-at-top-p listener)
    (let* ((inspector (first *inspectors*))
           (list (inspector-object inspector))
           (table (getf (inspector-pane-parts inspector 0) :table))
           (insert (inspector-part inspector :insert-button)))
      (check-step (and (live-pointer-p insert) (not (objc:invoke-bool insert "isEnabled")))
                  "has an Insert button, with nothing selected to insert before")
      (select-restart-row table 1)
      (pump 0.1d0)
      (check-step (objc:invoke-bool insert "isEnabled") "which a selected element enables")
      (objc:invoke (inspector-part inspector :add-value) "setStringValue:" "(list 1 2)")
      (objc:invoke insert "performClick:" nil)
      (check-step (wait-for (lambda () (equal list '(:a (1 2) :b :c))) :timeout 10)
                  "Insert puts the value in before the selected row")
      (check-step (wait-for (lambda () (= 4 (objc:invoke table "numberOfRows"))) :timeout 10)
                  "and the table has a row more")
      (select-restart-row table 0)
      (pump 0.1d0)
      (objc:invoke (inspector-part inspector :remove-button) "performClick:" nil)
      (check-step (wait-for (lambda () (equal list '((1 2) :b :c))) :timeout 10)
                  "Remove takes an element out, the first included, and it is the same list"))
    ;; A pointer is an address until somebody says what it is.
    (type-and-submit listener "(inspect (objc:invoke \"NSProcessInfo\" \"processInfo\"))")
    (check-step (wait-for (lambda () (newest-inspector-ready-p 3)) :timeout 15)
                "an inspector on a foreign pointer")
    (back-at-top-p listener)
    (let ((inspector (first *inspectors*)))
      (check-step (equal (first (inspector-pane-titles inspector)) "Pointer")
                  "shows it as a pointer, and asks it nothing")
      (let ((index (position "Treat as Objective-C object"
                             (model-controls (inspector-model inspector))
                             :key #'control-model-label :test #'string=)))
        (check-step index "with a button to say it is an Objective-C object")
        (when index
          (objc:invoke (nth index (inspector-part inspector :control-views))
                       "performClick:" nil)
          (check-step (wait-for (lambda ()
                                  (and (= 2 (length (model-path (inspector-model inspector))))
                                       (objc-object-p (inspector-object inspector))))
                                :timeout 10)
                      "which walks into it as one")
          (pump-for 0.2d0)
          (check-step (equal (first (inspector-pane-titles inspector)) "Objective-C")
                      "in the view for an Objective-C object")
          (let ((row (inspector-table-row-of inspector 0 "class")))
            (check-step (and row (search "ProcessInfo"
                                         (second (row-cells (inspector-pane-row inspector 0 row)))))
                        "which says its class: ~a"
                        (and row (second (row-cells (inspector-pane-row inspector 0 row)))))))))
    ;; An NSArray: matched by class, and its elements walked into.
    (type-and-submit listener
                     "(inspect (inspector:objc (objc:invoke (objc:invoke \"NSProcessInfo\" \"processInfo\") \"arguments\")))")
    (check-step (wait-for (lambda () (newest-inspector-ready-p 4)) :timeout 15)
                "an inspector on an NSArray")
    (back-at-top-p listener)
    (let ((inspector (first *inspectors*)))
      (check-step (equal (first (inspector-pane-titles inspector)) "Elements")
                  "opens on its elements: the view matched by its class")
      (check-step (plusp (objc:invoke (getf (inspector-pane-parts inspector 0) :table)
                                      "numberOfRows"))
                  "a row an element")
      (inspector-open-row inspector 0 0)
      (check-step (wait-for (lambda ()
                              (and (= 2 (length (model-path (inspector-model inspector))))
                                   (equal (first (inspector-pane-titles inspector)) "Text")))
                            :timeout 10)
                  "an element is an object too, and an NSString opens as its text")
      (check-step (plusp (length (pane-model-text (pane-model-of inspector 0))))
                  "which is the program's first argument: ~a"
                  (clip-string (pane-model-text (pane-model-of inspector 0)) 60)))
    ;; A window: a view of AppKit's own in the pane, and controls that change it.
    (inspect-object (inspector:objc (listener-window listener)) listener)
    (check-step (wait-for (lambda () (newest-inspector-ready-p 5)) :timeout 15)
                "an inspector on the listener's own NSWindow")
    (let* ((inspector (first *inspectors*))
           (window (listener-window listener))
           (host (getf (inspector-pane-parts inspector 0) :native-host)))
      (check-step (equal (first (inspector-pane-titles inspector)) "Picture")
                  "opens on its picture")
      (check-step (and (not (objc:invoke-bool host "isHidden"))
                       (= 1 (objc:invoke (objc:invoke host "subviews") "count")))
                  "which is an NSImageView, put in the pane as it is")
      (let* ((controls (model-controls (inspector-model inspector)))
             (opacity (position "Opacity" controls :key #'control-model-label :test #'string=)))
        (check-step opacity "and has an Opacity slider among its controls")
        (when opacity
          (let ((slider (nth opacity (inspector-part inspector :control-views))))
            (objc:invoke slider "setDoubleValue:" 0.5d0)
            (send-control-action slider)
            (check-step (wait-for (lambda () (< (abs (- 0.5d0 (objc:invoke window "alphaValue")))
                                                0.01d0))
                                  :timeout 10)
                        "moving it changes the window, on the main thread")
            (picture (inspector-part inspector :window) "inspector-window.png")
            (objc:invoke slider "setDoubleValue:" 1d0)
            (send-control-action slider)
            (check-step (wait-for (lambda () (> (objc:invoke window "alphaValue") 0.99d0))
                                  :timeout 10)
                        "and back")))))
    (hide-inspectors)
    (pump-for 0.3d0)
    (check-step (null *inspectors*) "and these close as the others did")))

(defun debugger-test-arglist (listener directory)
  "The hint in the window's subtitle: what the call being typed takes, and the
argument at the caret."
  (let* ((view (listener-view-object listener))
         (pointer (listener-view listener))
         (window (listener-window listener)))
    (flet ((type-input (text)
             (replace-pending-input view pointer text)
             ;; As a keystroke leaves it: the caret at the end, which is what
             ;; AppKit tells the delegate of.
             (objc:invoke pointer "setSelectedRange:" (cons (transcript-length pointer) 0))
             (pump 0.1d0))
           (subtitle ()
             (objc:ns-string-to-string (objc:invoke window "subtitle"))))
      (type-input "(mapcar #'1+ ")
      (check-step (search "(mapcar function ‹list› &rest more-lists)" (subtitle))
                  "typing (mapcar #'1+ puts what MAPCAR takes under the title: ~s" (subtitle))
      (write-window-png window (namestring (merge-pathnames
                                            "arglist.png"
                                            (uiop:ensure-directory-pathname directory))))
      (type-input "(let ((x 1)) (format t ")
      (check-step (search "(format destination ‹control-string› &rest" (subtitle))
                  "inside a LET, the innermost call: ~s" (subtitle))
      (setf (preference :arglist-hints) nil)
      (preferences-changed)
      (check-step (equal "" (subtitle)) "switched off in Settings, it goes")
      (setf (preference :arglist-hints) t)
      (type-input "")
      (check-step (equal "" (subtitle)) "and with nothing typed there is nothing to say"))))

(defun run-debugger-test ()
  "Drive the pane and check it.  Exits 0 only when every check held."
  (let ((listener *listener*)
        (directory (uiop:getenv "LISP_LISTENER_DEBUGGER_TEST")))
    (ensure-directories-exist (uiop:ensure-directory-pathname directory))
    (unless (wait-for (lambda () (waiting-at-top-level-p listener)) :timeout 20)
      (note "debugger-test: no prompt after 20s")
      (finish-and-exit 3))
    (debugger-test-docking listener)
    (debugger-test-frames listener directory)
    (debugger-test-keyboard listener)
    (debugger-test-divider listener)
    (debugger-test-value listener directory)
    (debugger-test-pending-input listener)
    (debugger-test-line-start listener)
    (debugger-test-arglist listener directory)
    (debugger-test-levels listener)
    (debugger-test-history listener)
    (debugger-test-two-listeners listener)
    (debugger-test-files listener directory)
    (debugger-test-canvas listener directory)
    (debugger-test-settings listener directory)
    (debugger-test-windows listener)
    (debugger-test-inspector listener directory)
    (debugger-test-inspector-more listener directory)
    (note "debugger-test: ~:[~d FAILED~;PASS~]"
          (zerop *debugger-test-failures*) *debugger-test-failures*)
    (finish-and-exit (if (zerop *debugger-test-failures*) 0 1))))
