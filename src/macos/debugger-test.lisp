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
    (press-key-equivalent window "1")
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
    (note "debugger-test: ~:[~d FAILED~;PASS~]"
          (zerop *debugger-test-failures*) *debugger-test-failures*)
    (finish-and-exit (if (zerop *debugger-test-failures*) 0 1))))
