;;;; src/ios/app.lisp -- the iOS application: one listener, filling the screen.
;;;;
;;;; asdf-ios-app owns main() and UIApplicationMain.  When the scene connects it
;;;; boots ECL, makes a window with a plain root view controller, and calls
;;;; IOS-START on the main thread, which must RETURN so the run loop can go on.
;;;; So this is the Mac's BUILD-LISTENER without the application: there is no
;;;; menu, no second window and no run loop to enter.

(in-package #:lisp-listener)

(defun ios-start ()
  "The entry point.  Main thread; returns once the listener is running.

The order is the Mac's and for the same reason: the view first, then the
target the listener thread hops to, and only then the thread."
  ;; asdf-ios-app copies standard output into the app's Documents/console.log,
  ;; which is the one place a failure here can be read back from.
  (setf *log* *standard-output*)
  (objc:ensure-objc-initialized)
  (reset-transcript-attributes)
  ;; The canvas's names, in CL-USER before the init file, which may draw.
  (install-user-vocabulary)
  (load-init-file)
  (let ((listener (make-listener))
        (restarts (make-instance 'restarts-controller))
        (history (make-instance 'history-controller))
        (root (uikit:root-view)))
    (setf (controller-listener restarts) listener
          (getf (listener-retained listener) :restarts-controller) restarts
          (history-controller-listener history) listener
          (getf (listener-retained listener) :history-controller) history)
    (multiple-value-bind (pointer object) (make-listener-view)
      (setf (listener-view listener) pointer
            (listener-view-object listener) object
            (listener-window listener) (uikit:key-window))
      (objc:invoke root "setBackgroundColor:"
                   (objc:invoke "UIColor" "systemBackgroundColor"))
      (objc:invoke root "addSubview:" pointer)
      (let ((safe (objc:invoke root "safeAreaLayoutGuide")))
        (uikit:pin pointer "topAnchor" safe "topAnchor")
        (uikit:pin pointer "leadingAnchor" safe "leadingAnchor" 4)
        (uikit:pin pointer "trailingAnchor" safe "trailingAnchor" -4))
      ;; Above the keyboard, not under it, and following it as it comes and
      ;; goes -- the key bar included.
      (uikit:pin pointer "bottomAnchor"
                 (objc:invoke root "keyboardLayoutGuide") "topAnchor")
      (register-listener listener)
      (setf *listener* listener
            *main-thread-target* pointer)
      (install-open-url-hook)
      (warm-selectors listener)
      (start-listener-thread listener)
      (report-init-file listener)
      ;; The banner was written before there was anywhere to put it.
      (force-output (listener-output listener))
      (objc:invoke pointer "becomeFirstResponder")
      (let ((test (getenv "LISP_LISTENER_SELF_TEST")))
        (when test
          (start-self-test listener (or (ignore-errors (parse-integer test)) 0)))))
    listener))

(defun current-listener ()
  "The one listener there is."
  (or *listener* (first *listeners*)))

;;; A file from Files -----------------------------------------------------------
;;;
;;; The bundle declares .lisp as a document type (lisp-listener-ios.asd), so
;;; Files and a share sheet offer the listener for one.  asdf-ios-app's scene
;;; delegate hands the URL to IOS-APP-RUNTIME:*OPEN-URL-HOOK*, whether it
;;; launched the app or found it running, and this is the hook: the file is
;;; loaded by typing (load "...") at the prompt, as File > Open... does on the
;;; Mac.

(defun open-url (url-string)
  "Load the Lisp file URL-STRING names.  Thread 1.

The URL is security scoped and this is the only moment the file can be read,
while the load itself happens later on the listener thread: so a file from
outside the app's own documents is copied in first (IMPORT-OPENED-FILE)."
  (let ((listener (current-listener))
        (url (objc:invoke "NSURL" "URLWithString:" url-string)))
    (cond ((not (and listener (live-pointer-p url) (objc:invoke-bool url "isFileURL")))
           (note "open: nothing to do with ~a" url-string)
           nil)
          (t
           (let ((path (objc:ns-string-to-string (objc:invoke url "path"))))
             (cond ((loadable-file-p path)
                    ;; Copied NOW, whenever it is loaded.
                    (load-when-prompted
                     listener (list (import-opened-file path (history-directory))))
                    t)
                   (t (note "open: ~a is not a Lisp file" path)
                      nil)))))))

(defun first-prompt-shown-p (listener)
  "Whether LISTENER's first prompt is on screen: printed by its thread, and
flushed into the view."
  (let ((prompt (listener-prompt listener))
        (pointer (listener-view listener)))
    (and (listener-package listener)
         (or (null prompt)                ; already past it, and evaluating
             (let ((length (transcript-length pointer)))
               (and (>= length (length prompt))
                    (search prompt (transcript-substring pointer 0 length)
                            :from-end t)))))))

(defun load-when-prompted (listener paths)
  "Load PATHS at LISTENER's prompt -- once it has one.

A file that LAUNCHED the app arrives the moment the entry point returns, when
the listener thread has printed half a banner and no prompt: typed then, the
load was spliced into the middle of `ECL 26.5.5'.  So at startup it waits, on a
timer, for the first prompt to be on screen (or for five seconds, whichever
is first: a file not loaded is worse than one loaded untidily)."
  (if (first-prompt-shown-p listener)
      (load-files-into-listener listener paths)
      (let ((tries 0))
        (uikit:after-every
         0.1d0
         (lambda (timer)
           (when (or (first-prompt-shown-p listener) (> (incf tries) 50))
             (objc:invoke timer "invalidate")
             (load-files-into-listener listener paths)))))))

(defun install-open-url-hook ()
  "Tell asdf-ios-app's runtime where URLs go.  By name, at run time: the
package is the app's, and is not there when this file is compiled off a Mac."
  (let* ((package (find-package "IOS-APP-RUNTIME"))
         (hook (and package (find-symbol "*OPEN-URL-HOOK*" package))))
    (if hook
        (setf (symbol-value hook) 'open-url)
        (note "open: this asdf-ios-app has no *OPEN-URL-HOOK*; files cannot be opened"))))

;;; The self-test -------------------------------------------------------------
;;;
;;; Started when LISP_LISTENER_SELF_TEST is set -- `xcrun simctl launch' passes
;;; it on as SIMCTL_CHILD_LISP_LISTENER_SELF_TEST.  It drives the listener the
;;; way a person would, through SUBMIT-INPUT, the Tab key and the restarts
;;; sheet, and writes one line per step to the log, which is console.log.  The
;;; value is how many seconds to hold on each screen worth photographing.
;;;
;;; A timer drives it, not a loop: this is the main thread, and every answer
;;; from the listener thread arrives through a hop the main thread has to be
;;; free to service.

(defvar *self-test* nil)

(defstruct (self-test (:constructor make-self-test (listener hold steps)))
  listener hold steps (started (get-internal-real-time)) timer (failures 0))

(defun self-test-text (listener)
  (let ((view (listener-view listener)))
    (transcript-substring view 0 (transcript-length view))))

(defun at-top-level-prompt-p (listener)
  (let* ((text (self-test-text listener))
         (line (subseq text (1+ (or (position #\Newline text :from-end t) -1)))))
    (and (search "CL-USER>" line) (not (find #\[ line)))))

(defun type-into-view (pointer text)
  "Type TEXT one character at a time the way UIKit does it.

UIKit\'s contract is: ask the delegate whether the change may go ahead, and
apply it only if the delegate says yes -- a NO means the delegate did whatever
was wanted itself, which is how the paredit hook works.  So each character is
offered to that method and inserted only when it answers true.

-insertText: is NOT the way in: called programmatically it does not consult the
delegate at all, so it walked straight past the hook this is here to test."
  (loop for character across text
        for caret = (caret-index pointer)
        do (when (objc:invoke-bool pointer
                                   "textView:shouldChangeTextInRange:replacementText:"
                                   pointer (cons caret 0) (string character))
             (objc:invoke pointer "insertText:" (string character))))
  text)

(defun type-line (listener text)
  (let ((view (listener-view-object listener))
        (pointer (listener-view listener)))
    (replace-pending-input view pointer text)
    (submit-input view pointer)))

(defun build-self-test-steps (listener)
  "Each step: a label, a predicate that says it may run, and what it does.
A step whose predicate has not held within its time fails."
  ;; Each step that touches the view looks it up itself: the steps run one per
  ;; tick, long after this list was built.
  (list
   (list "the listener prompts" (lambda () (at-top-level-prompt-p listener)) nil)
   ;; What the last launch left behind.  Zero on a first run, which is not a
   ;; failure -- the number is the interesting part, so it is logged.
   (list "init.lisp" (constantly t)
         (lambda ()
           (note "selftest: init file ~s, C-M-t bound to ~a"
                 *init-file-loaded* (paredit-key "C-M-t"))))
   (list "the saved history is loaded" (constantly t)
         (lambda ()
           (note "selftest: history has ~d line~:p from earlier launches"
                 (length (view-history (listener-view-object listener))))))
   (list "(+ 1 2) is typed" (constantly t) (lambda () (type-line listener "(+ 1 2)")))
   (list "it evaluates to 3"
         (lambda () (let ((text (self-test-text listener)))
                      (search (format nil "~%3~%") text)))
         nil)
   (list "Tab completes multiple-value-b"
         (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (let ((view (listener-view-object listener))
                 (pointer (listener-view listener)))
             (replace-pending-input view pointer "(multiple-value-b")
             (complete-at-caret view pointer)
             (unless (string= (pending-input view pointer) "(multiple-value-bind")
               (error "completed to ~s" (pending-input view pointer)))
             (replace-pending-input view pointer ""))))
   ;; The history list: opened, narrowed, and a row chosen, which puts the
   ;; line in the input region without submitting it.
   (list "the history list opens and narrows"
         (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (let ((view (listener-view-object listener)))
             ;; Something to find, whatever earlier launches left behind.
             (setf (view-history view)
                   (list "(list :from-the-history)" "(+ 40 2)"))
             (unless (open-history-popup listener)
               (error "the list would not open"))
             (unless (history-popup-visible-p listener)
               (error "the list is not on screen"))
             (unless (eql 2 (history-row-count listener))
               (error "~a rows, wanted 2" (history-row-count listener)))
             (type-history-query "from" listener)
             (unless (eql 1 (history-row-count listener))
               (error "~a rows after narrowing, wanted 1"
                      (history-row-count listener))))))
   ;; Left on screen, narrowed, for the hold to be photographed.
   (list :hold nil nil)
   (list "and a chosen row lands in the input region, unsubmitted"
         (constantly t)
         (lambda ()
           (let ((view (listener-view-object listener))
                 (pointer (listener-view listener)))
             (choose-history-row listener 0)
             (unless (string= (pending-input view pointer)
                              "(list :from-the-history)")
               (error "chose ~s" (pending-input view pointer)))
             (when (history-popup-visible-p listener)
               (error "the list stayed on screen"))
             (replace-pending-input view pointer ""))))
   ;; Paredit, through the same delegate a keyboard goes through: each
   ;; character is offered to -textView:shouldChangeTextInRange:replacementText:
   ;; exactly as UIKit offers it.
   (list "paredit balances what is typed" (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (let ((view (listener-view-object listener))
                 (pointer (listener-view listener)))
             (replace-pending-input view pointer "")
             (type-into-view pointer "(list 1 2")
             (unless (string= (pending-input view pointer) "(list 1 2)")
               (error "( did not auto-close: ~s" (pending-input view pointer)))
             (type-into-view pointer ")")
             (unless (string= (pending-input view pointer) "(list 1 2)")
               (error ") doubled the paren: ~s" (pending-input view pointer)))
             ;; The highlight: the caret is just past the close paren.
             (refresh-paren-highlight view pointer)
             (unless (= 2 (length (view-paren-marks view)))
               (error "~d paren~:p tinted, wanted 2"
                      (length (view-paren-marks view))))
             ;; And a structural command, as its key would run it.
             (replace-pending-input view pointer "(list (a) b)")
             (objc:invoke pointer "setSelectedRange:"
                          (cons (+ (view-input-start view) 8) 0))
             (unless (run-paredit-at-caret view pointer 'slurp-forward)
               (error "slurp declined"))
             (unless (string= (pending-input view pointer) "(list (a b))")
               (error "slurp gave ~s" (pending-input view pointer)))
             ;; Left on screen, tinted, for the hold below to be photographed.
             (replace-pending-input view pointer "(defun f (x) (list x))")
             (objc:invoke pointer "setSelectedRange:"
                          (cons (transcript-length pointer) 0))
             (refresh-paren-highlight view pointer))))
   (list :hold nil nil)
   (list "the tinted pair is cleared away" (constantly t)
         (lambda ()
           (let ((view (listener-view-object listener))
                 (pointer (listener-view listener)))
             (replace-pending-input view pointer ""))))
   ;; Stop, on a form half read.  A form still RUNNING is stopped at the end
   ;; of this list: if that ever fails nothing gets the listener back, so it
   ;; goes last, where it can fail only itself.
   (list "Stop is asked, mid-form" (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (let ((view (listener-view-object listener))
                 (pointer (listener-view listener)))
             (replace-pending-input view pointer "(list 1")
             (submit-input view pointer))
           (abort-evaluation listener)))
   (list "Stop abandons a half-read form"
         (lambda () (let ((text (self-test-text listener)))
                      (search "; Aborted." text)))
         nil)
   (list "an error is typed" (constantly t)
         (lambda () (type-line listener "(error \"boom\")")))
   (list "the restarts sheet appears" (lambda () (restarts-panel-visible-p listener))
         nil)
   ;; The table, not just the sheet: a data source that was never found
   ;; answers zero, and a sheet of blank rows looks identical in a picture.
   (list "its table has a row per restart" (constantly t)
         (lambda ()
           (let ((rows (restarts-table-row-count listener)))
             (unless (and rows (>= rows 2))
               (error "the table has ~a rows" rows)))))
   (list "and the frames under them" (constantly t)
         (lambda ()
           (let* ((table (listener-restarts-table listener))
                  (sections (objc:invoke table "numberOfSections"))
                  (frames (and (> sections 1)
                               (objc:invoke table "numberOfRowsInSection:" 1))))
             (unless (and frames (plusp frames))
               (error "~a section~:p, ~a frame row~:p" sections frames)))))
   (list "Backtrace scrolls to them" (constantly t)
         (lambda ()
           (unless (show-sheet-backtrace listener)
             (error "there was no sheet to show them in"))))
   (list "and they are on screen"
         (lambda ()
           (let* ((table (listener-restarts-table listener))
                  (visible (objc:invoke table "indexPathsForVisibleRows")))
             (loop for i from 0 below (objc:invoke visible "count")
                   thereis (= 1 (objc:invoke (objc:invoke visible "objectAtIndex:" i)
                                             "section")))))
         nil)
   (list :hold nil nil)
   (list "Cancel returns to the top level" (constantly t)
         (lambda ()
           (unless (cancel-to-top-level listener)
             (error "no top-level restart on offer"))))
   (list "the top-level prompt is back"
         (lambda () (and (at-top-level-prompt-p listener)
                         (not (restarts-panel-visible-p listener))))
         nil)
   ;; A restart that asks for a value asks in the sheet.  RESTART-CASE rather
   ;; than an unbound variable: ECL establishes no USE-VALUE around one.
   (list "a restart that asks is offered" (constantly t)
         (lambda ()
           (type-line listener
                      "(restart-case (error \"ask me\") (use-value (v) :report \"Use a value.\" :interactive (lambda () (list (eval (read)))) v))")))
   (list "choosing it opens the value field"
         (lambda () (restarts-panel-visible-p listener))
         (lambda ()
           (activate-restart 0 listener)
           (let* ((views (controller-views
                          (getf (listener-retained listener) :restarts-controller)))
                  (field (getf views :value-field)))
             (unless (eql 0 (getf views :value-index))
               (error "no question is being asked"))
             (when (objc:invoke-bool field "isHidden")
               (error "the field is hidden"))
             (objc:invoke field "setText:" "(* 6 7)"))))
   (list :hold nil nil)
   (list "the value is sent" (constantly t)
         (lambda ()
           (unless (submit-restart-value listener)
             (error "nothing was sent"))))
   (list "USE-VALUE with (* 6 7) returned 42"
         (lambda () (and (at-top-level-prompt-p listener)
                         (not (restarts-panel-visible-p listener))
                         (search (format nil "0 (* 6 7)~%42~%") (self-test-text listener))))
         nil)
   ;; ⌘0, through the key command's own IMP, as a keyboard would send it.
   (list "another error" (constantly t)
         (lambda () (type-line listener "(error \"again\")")))
   (list "⌘0 takes the top-level restart"
         (lambda () (restarts-panel-visible-p listener))
         (lambda ()
           (objc:invoke (listener-view listener) "listenerRestartKey:"
                        (key-command "0" "listenerRestartKey:" +ui-key-modifier-command+))))
   (list "and the top level is back"
         (lambda () (and (at-top-level-prompt-p listener)
                         (not (restarts-panel-visible-p listener))))
         nil)
   (list :hold nil nil)
   ;; The examples and the canvas.  Try lists them in the history's sheet; a
   ;; chosen one is put at the prompt, and Return runs it.
   (list "Try lists the examples" (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (unless (open-examples-popup listener)
             (error "the list would not open"))
           (unless (eql (length *examples*) (history-row-count listener))
             (error "~a rows, wanted ~d" (history-row-count listener) (length *examples*)))
           (type-history-query "spiral" listener)
           (unless (eql 1 (history-row-count listener))
             (error "~a rows after narrowing, wanted 1" (history-row-count listener)))))
   (list "and a chosen one is put at the prompt" (constantly t)
         (lambda ()
           (let ((view (listener-view-object listener))
                 (pointer (listener-view listener)))
             (choose-history-row listener 0)
             (unless (string= (pending-input view pointer) "(example \"spiral\")")
               (error "chose ~s" (pending-input view pointer))))))
   (list "Return runs it" (lambda () (not (history-popup-visible-p listener)))
         (lambda ()
           (submit-input (listener-view-object listener) (listener-view listener))))
   (list "the canvas comes up, painted"
         (lambda () (and (canvas-visible-p) (plusp *canvas-paints*)
                         (at-top-level-prompt-p listener)))
         (lambda ()
           (unless (= 140 (length (canvas-contents)))
             (error "~d shapes on it, wanted 140" (length (canvas-contents))))))
   (list :hold nil nil)
   (list "its arrows are what (key) answers" (constantly t)
         (lambda ()
           (loop while (canvas:key))
           (unless (press-canvas-key :left) (error "there is no left arrow"))
           (let ((key (canvas:key)))
             (unless (eq key :left) (error "(key) answered ~s" key)))))
   ;; An error while the canvas is up: the restarts go over it, not nowhere.
   (list "an error with the canvas up" (constantly t)
         (lambda () (type-line listener "(circle 0 0 :big)")))
   (list "puts the restarts over it" (lambda () (restarts-panel-visible-p listener)) nil)
   (list "Cancel takes them down" (constantly t)
         (lambda ()
           (unless (cancel-to-top-level listener)
             (error "no top-level restart on offer"))))
   (list "and leaves the canvas"
         (lambda () (and (at-top-level-prompt-p listener)
                         (not (restarts-panel-visible-p listener))
                         (canvas-visible-p)))
         nil)
   ;; Snake, left to itself: it runs into the wall after ten squares.
   (list "snake is played" (constantly t)
         (lambda () (type-line listener "(example \"snake\")")))
   (list "to the end of the game"
         (lambda () (and (at-top-level-prompt-p listener)
                         (find :text (canvas-contents) :key #'first)))
         nil)
   (list :hold nil nil)
   (list "Done puts the canvas away" (constantly t)
         (lambda ()
           (let ((done (cdr (assoc :done *canvas-pad*))))
             (unless (live-pointer-p done) (error "there is no Done button"))
             (objc:invoke done "sendActionsForControlEvents:" 64))))
   (list "and it is gone" (lambda () (not (canvas-visible-p))) nil)
   ;; A file from Files, as the scene delegate delivers one: a URL, to the
   ;; runtime's hook.  A space in the name, which the URL has to carry encoded.
   (list "a Lisp file is handed over by the system"
         (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (let* ((path (concatenate 'string (string-right-trim "/" (getenv "TMPDIR"))
                                     "/handed over.lisp"))
                  (deliver (find-symbol "DELIVER-URL" "IOS-APP-RUNTIME")))
             (with-open-file (out path :direction :output :if-exists :supersede)
               (write-string "(defun cl-user::handed-over () :from-files)" out))
             (unless (and deliver
                          (funcall deliver
                                   (objc:ns-string-to-string
                                    (objc:invoke (objc:invoke "NSURL" "fileURLWithPath:" path)
                                                 "absoluteString"))))
               (error "the runtime had nowhere to deliver it")))))
   (list "it is copied in and loaded at the prompt"
         (lambda () (and (at-top-level-prompt-p listener)
                         (search "Opened/handed over.lisp\")" (self-test-text listener))))
         (lambda () (type-line listener "(cl-user::handed-over)")))
   (list "and what it defined is there"
         (lambda () (search ":FROM-FILES" (self-test-text listener)))
         nil)
   ;; A form that never returns, stopped.  Until asdf-ios-app trapped ECL's
   ;; interrupt signal, the interrupt was lost and this was there until the app
   ;; was killed.
   (list "a form that never returns" (lambda () (at-top-level-prompt-p listener))
         (lambda () (type-line listener "(loop)")))
   (list :hold nil nil)
   (list "is still running" (lambda () (not (at-top-level-prompt-p listener)))
         (lambda () (abort-evaluation listener)))
   (list "and Stop gets the prompt back"
         (lambda ()
           (let* ((text (self-test-text listener))
                  (from (search "(loop)" text :from-end t)))
             (and from (search "; Aborted." text :start2 from)
                  (at-top-level-prompt-p listener))))
         nil)))

(defun start-self-test (listener hold)
  (setf *self-test* (make-self-test listener hold (build-self-test-steps listener)))
  (setf (self-test-timer *self-test*)
        (uikit:after-every 0.2d0 (lambda (timer)
                                   (declare (ignore timer))
                                   (self-test-tick *self-test*))))
  (note "selftest: started"))

(defun self-test-tick (test)
  (let* ((step (first (self-test-steps test)))
         (elapsed (/ (- (get-internal-real-time) (self-test-started test))
                     internal-time-units-per-second)))
    (flet ((next ()
             (pop (self-test-steps test))
             (setf (self-test-started test) (get-internal-real-time))))
      (cond
        ((null step)
         (objc:invoke (self-test-timer test) "invalidate")
         (note "selftest: ~:[FAIL (~d)~;PASS~]"
               (zerop (self-test-failures test)) (self-test-failures test)))
        ((eq (first step) :hold)
         (when (>= elapsed (self-test-hold test)) (next)))
        (t
         (destructuring-bind (label ready action) step
           (cond
             ((ignore-errors (funcall ready))
              (handler-case (progn (when action (funcall action))
                                   (note "selftest: ok    ~a" label))
                (error (condition)
                  (incf (self-test-failures test))
                  (note "selftest: FAIL  ~a: ~a" label condition)))
              (next))
             ((> elapsed 10)
              (incf (self-test-failures test))
              (note "selftest: FAIL  ~a: timed out" label)
              (next)))))))))
