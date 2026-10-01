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

(defun drop-files (listener paths)
  "Drop PATHS on LISTENER's view, as the Finder would.  Answers what the view's
-performDragOperation: answered."
  (let ((pasteboard (objc:invoke "NSPasteboard" "pasteboardWithUniqueName"))
        (urls (objc:invoke "NSMutableArray" "array"))
        (drag (make-instance 'test-drag)))
    (objc:invoke pasteboard "clearContents")
    (dolist (path paths)
      (objc:invoke urls "addObject:" (objc:invoke "NSURL" "fileURLWithPath:" path)))
    (objc:invoke pasteboard "writeObjects:" urls)
    (setf (test-drag-pasteboard drag) pasteboard)
    (prog1 (objc:invoke-bool (listener-view listener) "performDragOperation:"
                             (objc:objc-object-pointer drag))
      (objc:invoke pasteboard "releaseGlobally"))))

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
    (let ((before (length (transcript-text listener))))
      (drop-files listener (list text))
      (pump-for 0.3d0)
      (check-step (not (search "(load" (transcript-text listener) :start2 before))
                  "a text file dropped is not loaded")
      (replace-pending-input (listener-view-object listener) (listener-view listener) ""))
    (save-transcript listener saved)
    (let ((written (uiop:read-file-string saved :external-format :utf-8)))
      (check-step (and (search "CL-USER>" written) (search (load-form lisp) written))
                  "Save Transcript… writes the transcript, the load included"))))

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
    (debugger-test-levels listener)
    (debugger-test-history listener)
    (debugger-test-two-listeners listener)
    (debugger-test-files listener directory)
    (note "debugger-test: ~:[~d FAILED~;PASS~]"
          (zerop *debugger-test-failures*) *debugger-test-failures*)
    (finish-and-exit (if (zerop *debugger-test-failures*) 0 1))))
