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
  ;; A relative pathname -- (load "x.lisp"), (with-open-file (s "notes.txt"))
  ;; -- is the app's folder's, which is the only one it may write, and the one
  ;; the Files app shows.  Left alone it is the working directory, which is /.
  (let ((home (history-directory)))
    (when home
      (setf *default-pathname-defaults* home)))
  (objc:ensure-objc-initialized)
  (reset-transcript-attributes)
  ;; The canvas's names, in CL-USER before the init file, which may draw; and
  ;; the preferences before it, so that it has the last word.
  (install-user-vocabulary)
  (load-preferences)
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
        ;; Kept, not just pinned: a docked canvas takes the right of the window
        ;; and this is the constraint it switches off to do it.
        (setf *transcript-trailing*
              (objc:retain (constraint pointer "trailingAnchor" safe "trailingAnchor" -4)))
        (objc:invoke *transcript-trailing* "setActive:" t))
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

;;; Open..., from inside ----------------------------------------------------------
;;;
;;; The same thing in the other direction: the Open key, or ⌘O, puts up the
;;; system's document picker, and what is chosen there is loaded.

(objc:define-objc-class open-picker-delegate ()
  ()
  (:objc-class-name "LispListenerOpenPickerDelegate"))

(defvar *open-picker-delegate* nil
  "The picker's delegate, kept: a picker holds its delegate weakly.")

(defun open-picked-urls (urls listener)
  "Load the Lisp files among URLS, an NSArray of NSURL.  Thread 1.

Chosen in place, not as copies, so one of the app's own files is loaded where
it is; one from elsewhere is security scoped, and is copied in while access to
it is held -- the load itself comes later, on another thread."
  (let ((paths '()))
    (loop for i from 0 below (objc:invoke urls "count")
          for url = (objc:invoke urls "objectAtIndex:" i)
          for path = (objc:ns-string-to-string (objc:invoke url "path"))
          do (if (loadable-file-p path)
                 (let ((scoped (objc:invoke-bool url "startAccessingSecurityScopedResource")))
                   (unwind-protect
                        (push (import-opened-file path (history-directory)) paths)
                     (when scoped
                       (objc:invoke url "stopAccessingSecurityScopedResource"))))
                 (note "open: ~a is not a Lisp file" path)))
    (when (and listener paths)
      (load-when-prompted listener (nreverse paths)))
    (length paths)))

(objc:define-objc-method ("documentPicker:didPickDocumentsAtURLs:" :void)
    ((self open-picker-delegate)
     (picker objc:objc-object-pointer)
     (urls objc:objc-object-pointer))
  (declare (ignorable picker))
  (handler-case (open-picked-urls urls (current-listener))
    (error (condition) (note "documentPicker:didPickDocumentsAtURLs: ~a" condition))))

(defun lisp-content-types ()
  "The UTTypes of the files LOAD takes, as an NSArray.  By extension: the type
this app declares for .lisp is whatever the system says it is."
  (let ((types (objc:invoke "NSMutableArray" "array")))
    (dolist (extension *loadable-file-types* types)
      (let ((type (objc:invoke "UTType" "typeWithFilenameExtension:" extension)))
        (when (live-pointer-p type)
          (objc:invoke types "addObject:" type))))))

(defun show-open-picker (&optional (listener (current-listener)))
  "Put up the document picker, to choose Lisp files to load.  Thread 1."
  (when listener
    (unless *open-picker-delegate*
      (setf *open-picker-delegate* (uikit:keep (make-instance 'open-picker-delegate))))
    (let ((picker (objc:invoke (objc:invoke "UIDocumentPickerViewController" "alloc")
                               "initForOpeningContentTypes:asCopy:"
                               (lisp-content-types) nil)))
      (objc:invoke picker "setAllowsMultipleSelection:" t)
      (objc:invoke picker "setDelegate:"
                   (objc:objc-object-pointer *open-picker-delegate*))
      (objc:invoke (presenting-controller listener)
                   "presentViewController:animated:completion:" picker t nil)
      ;; The presenter holds it now; the +1 from -alloc is ours to drop.
      (objc:release picker)
      t)))

(defun open-picker-up-p (listener)
  "Whether the document picker is what is presented.  For the self-test."
  (let ((top (presenting-controller listener)))
    (and (live-pointer-p top)
         (objc:invoke-bool top "isKindOfClass:"
                           (objc:coerce-to-objc-class "UIDocumentPickerViewController")))))

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

(defvar *self-test-saved-init* nil
  "init.lisp as it was before the self-test edited it, to put back.")

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

(defvar *scroll-samples* '()
  "The transcript's vertical scroll offset, sampled while typing at the bottom
line, newest first.")

(defvar *typing-done* nil)

(defun type-slowly-and-sample (listener text)
  "Type TEXT a character every 60 ms, as a person might, and meanwhile sample
the transcript's scroll offset every 10 ms -- which is what jitter would show
up in: an offset that goes back and forth while nothing is scrolled."
  (let* ((pointer (listener-view listener))
         (remaining (coerce text 'list))
         (sampler nil))
    (setf *scroll-samples* '() *typing-done* nil)
    (setf sampler
          (uikit:after-every 0.01d0
                             (lambda (timer)
                               (declare (ignore timer))
                               (push (aref (objc:invoke pointer "contentOffset") 1)
                                     *scroll-samples*))))
    (uikit:after-every 0.06d0
                       (lambda (timer)
                         (if remaining
                             (type-into-view pointer (string (pop remaining)))
                             (progn
                               (objc:invoke timer "invalidate")
                               ;; A moment more, for whatever settles late.
                               (uikit:after-every 0.5d0
                                                  (lambda (late)
                                                    (objc:invoke late "invalidate")
                                                    (objc:invoke sampler "invalidate")
                                                    (setf *typing-done* t))
                                                  :repeats nil)))))
    t))

(defun scroll-jitter (samples)
  "How far the offset went back up, in total, over SAMPLES, oldest first:
typing at the bottom should only ever scroll down, or stay put."
  (loop for (a b) on samples
        while b
        when (< b a) sum (- a b)))

(defun type-line (listener text)
  (let ((view (listener-view-object listener))
        (pointer (listener-view listener)))
    (replace-pending-input view pointer text)
    (submit-input view pointer)))

(defun heart-points (&optional (count 70))
  "A heart, as canvas points, for the self-test's finger to draw."
  (loop for i from 0 to count
        for a = (* 2 pi (/ i count))
        collect (cons (* 4.6 16 (expt (sin a) 3))
                      (+ 8 (* 4.6 (- (* 13 (cos a)) (* 5 (cos (* 2 a)))
                                     (* 2 (cos (* 3 a))) (cos (* 4 a))))))))

(defvar *finger-lifted* t
  "False while DRAW-WITH-A-FINGER's finger is still on the canvas.")

(defun draw-with-a-finger (points)
  "Run a finger along POINTS, canvas (x . y)s, a point every thirtieth of a
second: down at the first, moving through the rest, up after the last.  Through
CANVAS-POINTER-EVENT, which is what the canvas's recognizer calls."
  (let ((remaining points)
        (first t))
    (setf *finger-lifted* nil)
    (uikit:after-every
     (/ 1d0 30)
     (lambda (timer)
       (let* ((view (canvas-view-pointer))
              (bounds (objc:invoke view "bounds"))
              (width (aref bounds 2)) (height (aref bounds 3))
              (scale (/ (min width height) 200d0)))
         (flet ((event (phase point)
                  (canvas-pointer-event phase
                                        (+ (/ width 2) (* scale (car point)))
                                        (- (/ height 2) (* scale (cdr point)))
                                        width height)))
           (cond ((null remaining)
                  (objc:invoke timer "invalidate")
                  (event :up (first (last points)))
                  (setf *finger-lifted* t))
                 (t (event (if first :down :move) (pop remaining))
                    (setf first nil)))))))))

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
   (list "C-a goes to the start of the line, after the prompt"
         (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (let ((view (listener-view-object listener))
                 (pointer (listener-view listener)))
             (replace-pending-input view pointer (format nil "(list 1~%      2)"))
             (objc:invoke pointer "setSelectedRange:"
                          (cons (+ (view-input-start view) 4) 0))
             (objc:invoke pointer "listenerLineStart:" (cffi:null-pointer))
             (unless (= (caret-index pointer) (view-input-start view))
               (error "on the first line the caret is ~d past the prompt"
                      (- (caret-index pointer) (view-input-start view))))
             (objc:invoke pointer "setSelectedRange:"
                          (cons (transcript-length pointer) 0))
             (objc:invoke pointer "listenerLineStart:" (cffi:null-pointer))
             (unless (= (caret-index pointer) (+ (view-input-start view) 8))
               (error "on the second line the caret is ~d past the prompt"
                      (- (caret-index pointer) (view-input-start view))))
             (replace-pending-input view pointer ""))))
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
   ;; Opened as the restarts' sheet was leaving, so UIKit put its arrival off,
   ;; and chosen from before it had arrived: it must go all the same, and not
   ;; merely be forgotten.  See DISMISS-SHEET-WHEN-SETTLED.
   (list "and the list really is put away"
         (lambda () (not (live-pointer-p
                          (objc:invoke (objc:invoke (objc:invoke (listener-view listener) "window")
                                                    "rootViewController")
                                       "presentedViewController"))))
         nil)
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
   (list "it is where the room allows: docked if wide, a sheet if not"
         (constantly t)
         (lambda ()
           (let ((docks (canvas-docks-p)))
             (note "selftest: the canvas is ~:[a sheet~;docked~]" docks)
             (unless (if docks (canvas-docked-p) (canvas-sheet-up-p))
               (error "docks-p ~a, docked ~a, sheet ~a"
                      docks (canvas-docked-p) (canvas-sheet-up-p)))
             (when docks
               ;; The transcript really did give up the room.
               (let ((text (aref (objc:invoke (listener-view listener) "frame") 2))
                     (root (aref (objc:invoke (uikit:root-view) "bounds") 2)))
                 (unless (< text (* 0.7 root))
                   (error "the transcript is ~,0f of ~,0f points wide" text root)))))))
   ;; The window's width changing under a canvas that is up, as a rotation
   ;; would change it: pretended, by moving the line between room and none.
   ;; Two steps, a tick apart, as two rotations would be: a sheet dismissed is
   ;; not gone until the run loop has turned.
   (list "and it moves when the room changes" (constantly t)
         (lambda ()
           (let ((docked (canvas-docked-p)))
             (let ((*canvas-dock-width* (if docked 1d9 0d0)))
               (unless (replace-canvas)
                 (error "it did not move"))
               (when (eq docked (canvas-docked-p))
                 (error "it is still ~:[a sheet~;docked~]" docked))))))
   (list "and back when it changes back"
         ;; Once a sheet that was dismissed has gone.
         (lambda () (not (and (canvas-docked-p) (canvas-sheet-up-p))))
         (lambda ()
           ;; Asked for here -- unless the transcript's own layout has asked
           ;; already, which is the real thing and what CI's iPad did first.
           ;; Either way it must end up where the room says.
           (replace-canvas)
           (unless (eq (canvas-docks-p) (canvas-docked-p))
             (error "it did not move back: docks ~a, docked ~a"
                    (canvas-docks-p) (canvas-docked-p)))))
   ;; A finger on the canvas, as its recognizer reports one.
   (list "a touch is the pointer, and a tap is a key" (constantly t)
         (lambda ()
           (loop while (canvas:key))
           (let* ((view (canvas-view-pointer))
                  (bounds (objc:invoke view "bounds"))
                  (recognizers (objc:invoke (objc:invoke view "gestureRecognizers") "count")))
             (unless (= 1 recognizers)
               (error "~d recognizers on the canvas, wanted 1" recognizers))
             (canvas-pointer-event :down (/ (aref bounds 2) 2) (/ (aref bounds 3) 2)
                                   (aref bounds 2) (aref bounds 3))
             (multiple-value-bind (x y down) (canvas:pointer)
               (unless (and down (< (abs x) 0.01) (< (abs y) 0.01))
                 (error "(pointer) answered ~a ~a ~a" x y down)))
             (unless (eq (canvas:key) :click)
               (error "a tap was not the key :click"))
             (canvas-pointer-event :up 0 0 (aref bounds 2) (aref bounds 3)))))
   ;; The canvas as a picture, both ways, into the app's own folder.
   (list "the canvas is saved as a PNG and as SVG" (constantly t)
         (lambda ()
           (type-line listener "(list (save \"selftest\") (save \"selftest.svg\"))")))
   (list "and both are there"
         (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (flet ((size (name)
                    (with-open-file (in (merge-pathnames name (history-directory))
                                        :element-type '(unsigned-byte 8)
                                        :if-does-not-exist nil)
                      (if in (file-length in) 0))))
             (unless (and (> (size "selftest.png") 2000) (> (size "selftest.svg") 2000))
               (error "selftest.png is ~d bytes and selftest.svg ~d"
                      (size "selftest.png") (size "selftest.svg"))))))
   ;; More of the examples, each held for a look.
   (list "a tree, every branch a smaller tree" (lambda () (at-top-level-prompt-p listener))
         (lambda () (type-line listener "(example \"tree\")")))
   (list "is drawn by a function that calls itself"
         (lambda () (and (at-top-level-prompt-p listener)
                         (= 511 (length (canvas-contents)))))
         nil)
   (list :hold nil nil)
   (list "the Mandelbrot set" (constantly t)
         (lambda () (type-line listener "(example \"mandelbrot\")")))
   (list "is twenty lines, with Lisp's complex numbers"
         (lambda () (and (at-top-level-prompt-p listener)
                         (> (length (canvas-contents)) 600)))
         nil)
   (list :hold nil nil)
   ;; Doodle, with a finger the self-test supplies.
   (list "the canvas takes a finger" (constantly t)
         (lambda () (type-line listener "(example \"doodle\")")))
   (list "(pointer) says where it is, and a line follows it"
         (lambda () (and (not (at-top-level-prompt-p listener))
                         (= 1 (length (canvas-contents)))
                         (find :text (canvas-contents) :key #'first)))
         (lambda () (draw-with-a-finger (heart-points))))
   (list "until the finger lifts"
         ;; Some lines, not all seventy: the doodle looks fifty times a
         ;; second when it can, and on a busy simulator it cannot.
         (lambda () (and *finger-lifted*
                         (> (count :line (canvas-contents) :key #'first) 10)))
         ;; Escape, which is how a doodle is given up early.
         (lambda () (canvas-push-key :escape)))
   (list "and what was drawn stays" (lambda () (at-top-level-prompt-p listener)) nil)
   (list :hold nil nil)
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
   ;; Settings, from its key: a switch and the size of the type, each in
   ;; force and written down the moment it is touched.
   (list "⚙ opens Settings" (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (unless (show-settings-sheet listener) (error "there was nothing to show"))))
   (list "a switch turns paredit off, and the stepper makes the type bigger"
         (lambda () (settings-sheet-up-p))
         (lambda ()
           (let ((switch (settings-control :paredit))
                 (stepper (settings-control :font-size))
                 (before *font-size*))
             (unless (objc:invoke-bool switch "isOn") (error "the switch shows paredit off"))
             (objc:invoke switch "setOn:animated:" nil t)
             (objc:invoke switch "sendActionsForControlEvents:" +ui-control-event-value-changed+)
             (when (or *paredit-enabled* (getf (read-preferences) :paredit t))
               (error "paredit is ~a and the file says ~a"
                      *paredit-enabled* (getf (read-preferences) :paredit t)))
             (objc:invoke stepper "setValue:" (+ before 4))
             (objc:invoke stepper "sendActionsForControlEvents:" +ui-control-event-value-changed+)
             (unless (= *font-size* (+ before 4))
               (error "the size is ~a, was ~a" *font-size* before)))))
   (list :hold nil nil)
   (list "and both are put back" (constantly t)
         (lambda ()
           (let ((switch (settings-control :paredit))
                 (stepper (settings-control :font-size)))
             (objc:invoke switch "setOn:animated:" t t)
             (objc:invoke switch "sendActionsForControlEvents:" +ui-control-event-value-changed+)
             (objc:invoke stepper "setValue:" (- *font-size* 4))
             (objc:invoke stepper "sendActionsForControlEvents:" +ui-control-event-value-changed+)
             (unless *paredit-enabled* (error "paredit is still off"))
             (hide-settings-sheet))))
   (list "Settings is put away" (lambda () (not (settings-sheet-up-p))) nil)
   ;; Typing on the bottom line must not shake the transcript.
   (list "the transcript is filled past the bottom of the screen"
         (lambda () (at-top-level-prompt-p listener))
         (lambda () (type-line listener "(dotimes (i 60) (print i))")))
   (list "a form is typed on the bottom line, a key at a time"
         (lambda () (and (at-top-level-prompt-p listener)
                         (search (format nil "~%59") (self-test-text listener))))
         (lambda () (type-slowly-and-sample listener "(list 1 2 3 (+ 4 5) \"six\" 7)")))
   (list "and the transcript does not jump about while it is"
         (lambda () *typing-done*)
         (lambda ()
           (let* ((samples (reverse *scroll-samples*))
                  (jitter (scroll-jitter samples)))
             (note "selftest: ~d scroll samples, from ~,1f to ~,1f, back up ~,1f points in all"
                   (length samples) (first samples) (first (last samples)) jitter)
             (replace-pending-input (listener-view-object listener) (listener-view listener) "")
             (when (> jitter 2)
               (error "the transcript went back up ~,1f points while typing" jitter)))))
   ;; The line over the keys says what the call being typed takes.
   (list "a function is defined, to be described" (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (type-line listener "(defun hinted (alpha beta &optional gamma) (list alpha beta gamma))")))
   (list "and typing a call to it says what it takes"
         (lambda () (and (at-top-level-prompt-p listener)
                         (search "HINTED" (self-test-text listener))))
         (lambda ()
           (let ((view (listener-view-object listener))
                 (pointer (listener-view listener)))
             ;; A function of the Lisp's own, whose lambda list ECL here can
             ;; only have from what was recorded when the app was compiled.
             (let ((builtin (arglist-hint "(mapcar " 8 (find-package "COMMON-LISP-USER"))))
               (unless (equal builtin "(mapcar function list &rest more-lists)")
                 (error "(mapcar is described as ~s" builtin)))
             (replace-pending-input view pointer "(hinted 1 ")
             (objc:invoke pointer "setSelectedRange:" (cons (transcript-length pointer) 0))
             (refresh-arglist-hint view pointer)
             (let ((shown (objc:ns-string-to-string
                           (objc:invoke (view-hint-label view) "text"))))
               (unless (equal shown "(hinted alpha beta &optional gamma)")
                 (error "the line over the keys says ~s" shown))))))
   (list :hold nil nil)
   (list "and nothing once the input is gone" (constantly t)
         (lambda ()
           (let ((view (listener-view-object listener))
                 (pointer (listener-view listener)))
             (replace-pending-input view pointer "")
             (refresh-arglist-hint view pointer)
             (let ((shown (objc:ns-string-to-string
                           (objc:invoke (view-hint-label view) "text"))))
               (unless (equal shown "")
                 (error "the line over the keys still says ~s" shown))))))
   ;; Home is the app's folder: a relative pathname and ~ both mean it.
   (list "the app's folder is home, to a relative pathname and to ~" (constantly t)
         (lambda ()
           (let ((home (namestring (history-directory))))
             (note "selftest: HOME ~a, user-homedir ~a, defaults ~a"
                   home (user-homedir-pathname) *default-pathname-defaults*)
             (unless (equal home (namestring *default-pathname-defaults*))
               (error "a relative pathname is under ~a" *default-pathname-defaults*))
             (unless (equal home (namestring (user-homedir-pathname)))
               (error "~~ is ~a" (user-homedir-pathname))))))
   ;; (download url): a file:// URL, so that the test needs no network; the
   ;; https:// path is the same call.
   (list "(download url) fetches a file" (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (let ((source (concatenate 'string (string-right-trim "/" (getenv "TMPDIR"))
                                      "/download-source.txt")))
             (with-open-file (out source :direction :output :if-exists :supersede)
               (write-string "fetched, not typed" out))
             (ignore-errors (delete-file (merge-pathnames "fetched.txt" (history-directory))))
             (type-line listener (format nil "(download \"file://~a\" \"fetched.txt\")"
                                         source)))))
   (list "into the app's folder, where Files shows it"
         (lambda () (and (at-top-level-prompt-p listener)
                         (search "fetched.txt" (self-test-text listener))))
         (lambda ()
           (let ((path (merge-pathnames "fetched.txt" (history-directory))))
             (unless (and (probe-file path)
                          (with-open-file (in path)
                            (equal (read-line in nil) "fetched, not typed")))
               (error "~a is not what was fetched" path)))))
   ;; init.lisp, edited from Settings and loaded at the prompt.  Put back as it
   ;; was afterwards: a self-test on a phone is somebody's phone.
   (list "Settings edits init.lisp" (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (let ((path (init-file-path)))
             (setf *self-test-saved-init*
                   (and (probe-file path)
                        (with-open-file (in path :external-format :utf-8)
                          (let ((string (make-string (file-length in))))
                            (subseq string 0 (read-sequence string in)))))))
           (show-settings-sheet listener)
           (let ((edit (settings-control :init-file)))
             (unless (live-pointer-p edit) (error "Settings has no Edit for init.lisp"))
             (objc:invoke edit "sendActionsForControlEvents:" 64))))
   (list "in a sheet of its own" (lambda () (init-editor-up-p))
         (lambda ()
           (unless (search "init.lisp" (objc:ns-string-to-string
                                        (objc:invoke *init-editor-text* "text")))
             (error "the editor does not hold init.lisp"))
           (objc:invoke *init-editor-text* "setText:"
                        "(defparameter cl-user::*from-init* (* 6 7))")))
   (list :hold nil nil)
   (list "and Save and Load writes it and loads it at the prompt" (constantly t)
         (lambda () (save-init-file-from-editor :load t)))
   (list "which is in force at once, with nothing left on screen"
         (lambda () (and (at-top-level-prompt-p listener)
                         (boundp 'cl-user::*from-init*)
                         (not (init-editor-up-p)) (not (settings-sheet-up-p))
                         (not (live-pointer-p
                               (objc:invoke (objc:invoke (objc:invoke (listener-view listener)
                                                                      "window")
                                                         "rootViewController")
                                            "presentedViewController")))))
         (lambda ()
           (unless (eql 42 (symbol-value 'cl-user::*from-init*))
             (error "*from-init* is ~a" (symbol-value 'cl-user::*from-init*)))
           (let ((saved *self-test-saved-init*)
                 (path (init-file-path)))
             (if saved
                 (with-open-file (out path :direction :output :if-exists :supersede
                                           :external-format :utf-8)
                   (write-string saved out))
                 (delete-file path)))))
   ;; The inspector, as a sheet: a list's elements, changed from its foot.
   (list "(inspect x) at the prompt" (lambda () (at-top-level-prompt-p listener))
         (lambda () (type-line listener "(inspect (list :alpha :beta))")))
   (list "puts the inspector's sheet up, on the list's elements"
         (lambda () (and (inspector-sheet-up-p) (inspector-model *inspector-shown*)))
         (lambda ()
           (let ((inspector *inspector-shown*))
             (unless (equal "Elements" (pane-model-view-title (sheet-pane-model inspector)))
               (error "it opened on ~a" (pane-model-view-title (sheet-pane-model inspector))))
             (unless (= 2 (objc:invoke (inspector-part inspector :table)
                                       "numberOfRowsInSection:" 0))
               (error "the table has ~d rows"
                      (objc:invoke (inspector-part inspector :table)
                                   "numberOfRowsInSection:" 0)))
             (select-inspector-row 1)
             (unless (equal ":BETA" (sheet-field-text inspector))
               (error "the field has ~s" (sheet-field-text inspector)))
             (objc:invoke (inspector-part inspector :field) "setText:" "(+ 40 2)")
             (unless (press-inspector-button :set)
               (error "Set could not be pressed")))))
   (list "Set puts a form's value at the selected row"
         (lambda () (equal (inspector-object *inspector-shown*) '(:alpha 42)))
         (lambda ()
           (objc:invoke (inspector-part *inspector-shown* :field) "setText:" ":new")
           (unless (press-inspector-button :insert)
             (error "Insert could not be pressed"))))
   (list "Insert puts one in before it"
         (lambda () (equal (inspector-object *inspector-shown*) '(:alpha :new 42)))
         (lambda ()
           (objc:invoke (inspector-part *inspector-shown* :field) "setText:" "(list 1 2)")
           (unless (press-inspector-button :add)
             (error "Add could not be pressed"))))
   (list "Add puts one on the end"
         (lambda () (equal (inspector-object *inspector-shown*) '(:alpha :new 42 (1 2))))
         (lambda ()
           (select-inspector-row 0)
           (unless (press-inspector-button :remove)
             (error "Remove could not be pressed"))))
   (list "Remove takes one out"
         (lambda () (equal (inspector-object *inspector-shown*) '(:new 42 (1 2))))
         (lambda ()
           (select-inspector-row 2)
           (unless (press-inspector-button :open)
             (error "Open could not be pressed"))))
   (list :hold nil nil)
   (list "Open walks into a row"
         (lambda () (and (equal (inspector-object *inspector-shown*) '(1 2))
                         (= 2 (length (model-path (inspector-model *inspector-shown*))))))
         (lambda ()
           (unless (press-inspector-button :back)
             (error "Back could not be pressed"))))
   (list "and Back walks out"
         (lambda () (= 1 (length (model-path (inspector-model *inspector-shown*)))))
         (lambda ()
           ;; The path's label is the list as it is NOW, not as it was opened.
           (let ((label (first (model-path (inspector-model *inspector-shown*)))))
             (unless (search ":NEW" label)
               (error "the path still says ~a" label)))
           (unless (press-inspector-button :all-views)
             (error "Views could not be pressed"))))
   (list "Views lists every view there is"
         (lambda () (views-list-up-p))
         (lambda ()
           (let* ((inspector *inspector-shown*)
                  (rows (inspector-part inspector :list-rows))
                  (table (inspector-part inspector :list-table))
                  (histogram (find "Histogram" rows :key (lambda (row) (getf row :title))
                                                    :test #'string=))
                  (object (position "Object" rows :key (lambda (row) (getf row :title))
                                                  :test #'string=)))
             (unless (= (length *views*) (objc:invoke table "numberOfRowsInSection:" 0))
               (error "the list has ~d rows for ~d views"
                      (objc:invoke table "numberOfRowsInSection:" 0) (length *views*)))
             (unless (and histogram (not (getf histogram :applies))
                          (search "Needs" (getf histogram :reason)))
               (error "the histogram's row says ~s" histogram))
             ;; A tap on one that applies.
             (objc:invoke (sheet-target inspector) "tableView:didSelectRowAtIndexPath:"
                          table
                          (objc:invoke "NSIndexPath" "indexPathForRow:inSection:" object 0)))))
   (list :hold nil nil)
   (list "and a tap on one that applies shows it, and puts the list away"
         (lambda () (and (not (views-list-up-p))
                         (equal "Object"
                                (pane-model-view-title (sheet-pane-model *inspector-shown*)))))
         (lambda ()
           ;; Another view, through the segmented control.
           (let* ((inspector *inspector-shown*)
                  (views (inspector-part inspector :views))
                  (index (position "Describe"
                                   (pane-model-choices (sheet-pane-model inspector))
                                   :key #'cdr :test #'string=)))
             (objc:invoke views "setSelectedSegmentIndex:" index)
             (objc:invoke views "sendActionsForControlEvents:"
                          +ui-control-event-value-changed+))))
   (list "choosing a view shows it"
         (lambda () (equal "Describe"
                           (pane-model-view-title (sheet-pane-model *inspector-shown*))))
         (lambda ()
           (unless (press-inspector-button :done)
             (error "Done could not be pressed"))))
   (list "Done puts the inspector away, and ends it"
         (lambda () (and (null *inspector-shown*) (null *inspectors*)))
         nil)
   ;; INSPECT's own value is not printed under it: ECL's answers its argument.
   (list "what was inspected is not printed again under the prompt"
         (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (let* ((text (self-test-text listener))
                  (from (search "(inspect (list :alpha :beta))" text :from-end t)))
             (when (search "(:ALPHA :BETA)" text :start2 from)
               (error "the transcript has the list after the form")))
           (type-line listener "(list :tap :me)")))
   ;; A printed value is the way to its inspector.
   (list "a tap on a printed value"
         (lambda () (and (at-top-level-prompt-p listener)
                         (search "(:TAP :ME)" (self-test-text listener))))
         (lambda ()
           (let* ((text (self-test-text listener))
                  (at (search "(:TAP :ME)" text)))
             (unless (tap-transcript-value listener (listener-view listener)
                                           (utf-16-length (subseq text 0 (1+ at))))
               (error "there was no value to open at ~d" at)))))
   (list "opens the inspector on it"
         (lambda () (and (inspector-sheet-up-p)
                         (equal (inspector-object *inspector-shown*) '(:tap :me))))
         (lambda () (hide-inspector)))
   (list "which is put away" (lambda () (null *inspectors*)) nil)
   ;; A drawing, with an option, and a readout under the finger.
   (list "a byte vector is inspected" (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (type-line listener
                      "(inspect (let ((v (make-array 256 :element-type '(unsigned-byte 8)))) (dotimes (i 256 v) (setf (aref v i) (mod (* i i) 256)))))")))
   (list "as a histogram, with its option"
         (lambda () (and (inspector-sheet-up-p)
                         (inspector-model *inspector-shown*)
                         (pane-model-drawing (sheet-pane-model *inspector-shown*))))
         (lambda ()
           (let* ((inspector *inspector-shown*)
                  (drawing (inspector-part inspector :drawing))
                  (slider (first (inspector-part inspector :option-controls))))
             (when (objc:invoke-bool drawing "isHidden")
               (error "the drawing is hidden"))
             (unless (live-pointer-p slider)
               (error "there is no control for the bins"))
             (objc:invoke slider "setValue:" 16.0)
             (objc:invoke slider "sendActionsForControlEvents:"
                          +ui-control-event-value-changed+))))
   (list "moving the bins slider draws it again with 16"
         (lambda ()
           (eql 16 (count :rect (drawing-scene-ops
                                 (pane-model-drawing (sheet-pane-model *inspector-shown*)))
                          :key #'first)))
         (lambda ()
           ;; A finger in the middle of the drawing.
           (let* ((inspector *inspector-shown*)
                  (bounds (objc:invoke (inspector-part inspector :drawing) "bounds")))
             (when (< (aref bounds 3) 40)
               (error "the drawing is ~a points tall" (aref bounds 3)))
             (inspector-drawing-touch inspector :move
                                      (/ (aref bounds 2) 2) (/ (aref bounds 3) 2)))))
   (list "a finger on it is told what is under it"
         (lambda ()
           (let ((readout (drawing-view-readout
                           (inspector-part *inspector-shown* :drawing-object))))
             (and readout (search "bytes" (first readout)))))
         nil)
   (list :hold nil nil)
   (list "until it lifts" (constantly t)
         (lambda ()
           (let ((inspector *inspector-shown*))
             (inspector-drawing-touch inspector :up 0 0)
             (when (drawing-view-readout (inspector-part inspector :drawing-object))
               (error "the readout is still there")))))
   ;; An Objective-C object, shown by a view of UIKit's own; and a second
   ;; (inspect x) takes the sheet over from the first.
   (list "an Objective-C object is inspected" (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (type-line listener
                      "(inspect (inspector:objc (objc:invoke \"UIImage\" \"systemImageNamed:\" \"star.fill\")))")))
   (list "it takes the sheet over, as a picture in a view of UIKit's own"
         (lambda ()
           (let ((inspector *inspector-shown*))
             (and inspector (inspector-sheet-up-p inspector)
                  (objc-object-p (inspector-object inspector))
                  (inspector-model inspector)
                  (equal "Image" (pane-model-view-title (sheet-pane-model inspector)))
                  (= 1 (length *inspectors*)))))
         (lambda ()
           (let ((host (inspector-part *inspector-shown* :native-host)))
             (unless (and (not (objc:invoke-bool host "isHidden"))
                          (= 1 (objc:invoke (objc:invoke host "subviews") "count")))
               (error "the native view is not in the sheet")))))
   (list :hold nil nil)
   (list "and is put away" (constantly t) (lambda () (hide-inspector)))
   ;; A view of UIKit's own: the window, as it looks, and its subviews.
   (list "the window is inspected" (lambda () (and (null *inspectors*)
                                                   (at-top-level-prompt-p listener)))
         (lambda () (type-line listener "(inspect (inspector:objc (uikit:key-window)))")))
   (list "as a picture of itself, with its subviews to walk into"
         (lambda ()
           (let ((inspector *inspector-shown*))
             (and inspector (inspector-sheet-up-p inspector) (inspector-model inspector)
                  (equal "Picture" (pane-model-view-title (sheet-pane-model inspector))))))
         (lambda ()
           (let* ((inspector *inspector-shown*)
                  (host (inspector-part inspector :native-host)))
             (unless (= 1 (objc:invoke (objc:invoke host "subviews") "count"))
               (error "there is no picture in the sheet"))
             (unless (member "Subviews" (mapcar #'cdr (pane-model-choices
                                                       (sheet-pane-model inspector)))
                             :test #'string=)
               (error "the window has no Subviews view"))
             (inspector-select-view inspector 0 'ui-subviews-view))))
   (list :hold nil nil)
   (list "the subviews are rows, and a row walks into one"
         (lambda () (let ((pane (sheet-pane-model *inspector-shown*)))
                      (and (equal "Subviews" (pane-model-view-title pane))
                           (pane-model-table pane)
                           (plusp (table-model-count (pane-model-table pane))))))
         (lambda () (inspector-open-row *inspector-shown* 0 0)))
   (list "into a view of its own"
         (lambda () (let ((inspector *inspector-shown*))
                      (and (= 2 (length (model-path (inspector-model inspector))))
                           (objc-object-p (inspector-object inspector)))))
         (lambda () (hide-inspector)))
   (list "leaving no inspector"
         (lambda () (and (null *inspector-shown*) (null *inspectors*)
                         (at-top-level-prompt-p listener)))
         nil)
   ;; An example put at the prompt to change, rather than run.
   (list "an example is asked for, to edit" (lambda () (at-top-level-prompt-p listener))
         (lambda () (type-line listener "(example-edit \"hello\")")))
   (list "and its source is at the prompt, unsubmitted"
         (lambda ()
           (search "(circle 0 0 60)"
                   (pending-input (listener-view-object listener) (listener-view listener))))
         (lambda ()
           (replace-pending-input (listener-view-object listener) (listener-view listener) "")))
   ;; The size of the type: changed, in force, and written down.
   (list "the type is made bigger" (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (let ((before *font-size*))
             (change-font-size 3)
             (unless (and (= *font-size* (+ before 3))
                          (eql *font-size* (getf (read-preferences) :font-size)))
               (error "the size is ~a, was ~a, and the file says ~a"
                      *font-size* before (getf (read-preferences) :font-size))))))
   (list :hold nil nil)
   (list "and put back" (constantly t) (lambda () (change-font-size -3)))
   ;; Open..., as the key does it: the system's picker comes up.
   (list "Open puts up the document picker" (lambda () (at-top-level-prompt-p listener))
         (lambda ()
           (unless (show-open-picker listener)
             (error "there was nothing to show"))))
   (list "and it is the picker that is up" (lambda () (open-picker-up-p listener))
         (lambda ()
           (objc:invoke (presenting-controller listener)
                        "dismissViewControllerAnimated:completion:" nil nil)))
   (list "until it is put away" (lambda () (not (open-picker-up-p listener))) nil)
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
