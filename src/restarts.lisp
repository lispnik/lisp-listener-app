;;;; src/restarts.lisp -- the restarts on screen: choosing instead of typing.
;;;;
;;;; WHAT LISPWORKS DOES, since this is modelled on it.  When a condition is
;;;; signalled outside the IDE's own tools, LispWorks raises a NOTIFIER window:
;;;; the condition's report at the top, then the available restarts listed one
;;;; per line in the order COMPUTE-RESTARTS returns them, and you pick one.  The
;;;; IDE's Debugger tool shows the same list in a Restarts pane beside the
;;;; backtrace.  Two things about it are worth copying and are copied here: the
;;;; list is the restarts themselves rather than a fixed set of buttons, so
;;;; whatever a handler established shows up; and picking one is the same act as
;;;; choosing it at the prompt, not a separate mechanism.
;;;;
;;;; THIS IS AN ADDITION.  The transcript still prints the numbered list and the
;;;; [1] CL-USER> prompt still takes a number, exactly as before; the panel is a
;;;; second way to reach the same thing.  Which is why it works the way it does:
;;;;
;;;;   *** THE BUTTONS TYPE FOR YOU. ***
;;;;
;;;; A button's action runs on thread 1, but a restart has to be invoked on the
;;;; listener thread, inside the dynamic extent of the debugger that established
;;;; it -- transfer control from the wrong thread and it is not that restart at
;;;; all.  The listener thread is already sitting in READ-LINE waiting for
;;;; exactly this answer, so the button types the number at the prompt and
;;;; presses Return, and the existing path does the rest.  No second mechanism,
;;;; no cross-thread control transfer, and nothing new that can deadlock.  A
;;;; restart that wants a value is answered the same way, with `1 42': the
;;;; panel asks for the form, and the line carries both.
;;;;
;;;; This file is what the two front ends share: the titles, which restart
;;;; Cancel means, and the hop to put them up and take them down.  The panel
;;;; itself is the front end's -- an NSPanel with a table in
;;;; src/macos/restarts-panel.lisp, an action sheet in src/ios/restarts-sheet.lisp
;;;; -- behind SHOW-RESTARTS-PANEL, HIDE-RESTARTS-PANEL and
;;;; RESTARTS-PANEL-VISIBLE-P.
;;;;
;;;; The panel is NOT modal, and that is also deliberate.  A modal panel would
;;;; hold thread 1 in a nested run loop while the listener thread waited for a
;;;; click -- fine in principle, and an immediate deadlock for anything driving
;;;; the listener from thread 1, which is what the screenshot script does.

(in-package #:lisp-listener)

(defparameter *restarts-panel-enabled* t
  "Whether entering the debugger also puts the restarts on screen.
NIL leaves the transcript's numbered list as the only way in, which is what it
was before this file existed.")

;;; The controller -------------------------------------------------------------

(objc:define-objc-class restarts-controller ()
  ((cancel-index :initform nil :accessor controller-cancel-index
                 :documentation "Which row Cancel takes: the index, in the rows
being shown, of the restart that returns to the listener's top level.  NIL when
it is not among them, in which case Cancel can only close the panel.")
   (listener :initform nil :accessor controller-listener
             :documentation "The listener whose panel this controller drives.

One per listener, unlike the menu bar's controller.  The panel's buttons have
to reach the listener that established the restarts, and `whichever window is
in front' would be the wrong answer: a background window is perfectly able to
be the one sitting in the debugger.")
   (titles :initform '() :accessor controller-titles
           :documentation "The rows the table is showing, RESTART-ROWs.

Held on the controller because a data source is asked for its rows whenever
AppKit feels like redrawing, long after the panel was built.  One debugger
level has a panel at a time, so one list is enough; HIDE-RESTARTS-PANEL
clears it.")
   (views :initform '() :accessor controller-views
          :documentation "The front end's own widgets for the panel on screen,
as a plist, for whatever has to find them again -- the Mac lays its panel out
afresh on every resize."))
  (:objc-class-name "LispListenerRestartsController"))

(defun type-into-listener (listener line)
  "Type LINE at LISTENER's prompt and press Return, as a person would.  Thread 1.

Through the view, so the transcript shows what was chosen -- `[1] CL-USER> 3'
-- exactly as if it had been typed; and whatever the person HAD typed there
is put back afterwards rather than sent along with it.  With no view, straight
onto the input queue."
  (let ((view (listener-view-object listener))
        (pointer (listener-view listener)))
    (if (and view pointer)
        (let ((pending (pending-input view pointer)))
          (replace-pending-input view pointer line)
          (submit-input view pointer :record nil)
          (when (plusp (length pending))
            (replace-pending-input view pointer pending)))
        (queue-push-string (listener-input listener) (format nil "~a~%" line))))
  line)

(defun choose-restart (index &optional value)
  "Take restart INDEX, with VALUE -- the text of a form -- when there is one.
Thread 1.

See the header: this TYPES the number rather than invoking the restart, because
the restart belongs to the listener thread and to the dynamic extent of the
debugger that established it.  With a value it types `1 42', which the debugger
reads as the restart and its value in one line; see RESTART-SELECTION."
  (let ((listener *listener*))
    (when (and listener (>= index 0))
      (hide-restarts-panel listener)
      (type-into-listener listener
                          (if value
                              ;; One line: the debugger reads lines.
                              (format nil "~d ~a" index
                                      (substitute #\Space #\Newline value))
                              (format nil "~d" index)))
      t)))

(defun restart-asks-p (restart)
  "True when invoking RESTART will stop and prompt for a value.

That is what a restart's interactive function IS -- INVOKE-RESTART-INTERACTIVELY
calls it, and SBCL's for USE-VALUE and STORE-VALUE print `Enter a form to be
evaluated: ' and READ one back.  So clicking such a row does not finish the
job, it starts a conversation in the transcript, and a trailing ellipsis is the Mac
convention for exactly that: a control that opens a prompt rather than acting.
Both the panel's rows and the transcript's numbered list are marked from here,
because they are two doors onto one list and must agree about it.

There is no portable predicate for this, so this reads an internal -- see
RESTART-INTERACTIVE-FUNCTION -- which answers NIL if it ever goes away.  Losing
an ellipsis is the whole cost of being wrong here; that is why a guarded
internal is acceptable for this and would not be for anything the behaviour
depends on."
  (and (restart-interactive-function restart) t))

(defstruct (restart-row (:constructor %make-restart-row))
  "One restart, as both doors show it: the transcript's numbered list and the
panel's rows.  Printed on the listener thread; see RESTART-ROWS."
  (index 0)
  (name "ANONYMOUS")
  (report "")
  ;; It will stop and ask for a value: see RESTART-ASKS-P.
  (asks-p nil)
  ;; Established outside the listener, below its own top-level restart --
  ;; SBCL's per-thread abort.  Taking it ends the listener.
  (outside-p nil))

(defun make-restart-row (index restart &optional toplevel-index)
  (let* ((outside (and toplevel-index (> index toplevel-index)))
         (name (princ-to-string (or (restart-name restart) "ANONYMOUS")))
         (report (handler-case (princ-to-string restart)
                   (error () "(unprintable restart)"))))
    (%make-restart-row
     :index index
     :name name
     ;; SBCL's reports as `abort thread (#<THREAD tid=64787 "lisp listener"
     ;; RUNNING {8009820453}>)': unreadable, cut off in any row it is put in,
     ;; and different on every run.  Beyond the listener's own restart there is
     ;; only the thread, so say that.
     :report (if (and outside (string-equal name "ABORT"))
                 "Abort the listener thread"
                 report)
     :asks-p (restart-asks-p restart)
     :outside-p outside)))

(defun restart-rows (restarts &optional toplevel-index)
  "RESTARTS as rows, computed HERE -- on the listener thread.

A restart's report may read the CURRENT thread rather than the one it was
established on.  SBCL's per-thread abort restart is exactly that: it reports as
`abort thread (#<THREAD ...>)' using SB-THREAD:*CURRENT-THREAD* at print time.
Printed from thread 1 while laying out the panel, it named the main thread and
was quietly wrong about which thread it would abort -- while the transcript,
printed on the listener thread, had it right all along.

Measured: a restart established on one thread and printed from another reports
the printing thread's name.  So the strings are made here and the panel is
handed text it cannot get wrong.

TOPLEVEL-INDEX is where the listener's own top-level restart sits; the rows
after it are marked as outside the listener."
  (loop for restart in restarts
        for index from 0
        collect (make-restart-row index restart toplevel-index)))

(defun restart-row-title (row)
  "ROW as one line of text: `0: [CONTINUE] Retry using *FOO*.', with an
ellipsis when it asks for a value."
  (format nil "~d: [~a] ~a~@[ …~]"
          (restart-row-index row) (restart-row-name row)
          (restart-row-report row) (restart-row-asks-p row)))

(defun restart-titles (restarts &optional toplevel-index)
  "RESTARTS as one line of text each.  On the listener thread."
  (mapcar #'restart-row-title (restart-rows restarts toplevel-index)))

(defun activate-restart (index &optional (listener *listener*))
  "Choose row INDEX -- double-clicked, Invoked, or its ⌘-number pressed.
Thread 1.

A restart that will ask for a value asks for it in the panel, where the front
end has somewhere to put it; any other is taken at once."
  (let* ((controller (and listener
                          (getf (listener-retained listener) :restarts-controller)))
         (row (and controller (nth index (controller-titles controller)))))
    (cond ((null row) nil)
          ((restart-row-asks-p row) (request-restart-value listener index) t)
          (t (let ((*listener* listener)) (choose-restart index))))))

(defun squeeze-whitespace (text)
  "TEXT with each run of whitespace reduced to one space, and trimmed.

A condition report is laid out over several indented lines; flattened into a
one-line heading, that indentation would survive as ragged gaps."
  (let ((out (make-string-output-stream))
        (pending nil)
        (started nil))
    (loop for character across text
          do (if (member character '(#\Space #\Tab #\Newline #\Return))
                 (when started (setf pending t))
                 (progn
                   (when pending (write-char #\Space out) (setf pending nil))
                   (write-char character out)
                   (setf started t))))
    (get-output-stream-string out)))

(defstruct (debugger-heading (:constructor make-debugger-heading
                                 (type report level)))
  "What the panel says above the restarts: the condition's type, its report,
and the debugger level it opened.  Printed on the listener thread, for the same
reason the rows are."
  (type "")
  (report "")
  (level 1))

(defparameter *heading-report-limit* 1000
  "The most of a condition's report the panel shows.  The transcript has all of
it; this only stops a report the size of a page from taking over the panel.")

(defun condition-heading (condition level)
  (let ((squeezed (squeeze-whitespace (report-condition condition))))
    (make-debugger-heading
     (princ-to-string (type-of condition))
     (if (> (length squeezed) *heading-report-limit*)
         (concatenate 'string (subseq squeezed 0 (- *heading-report-limit* 3)) "...")
         squeezed)
     level)))

(defun heading-line (heading)
  "HEADING as one line: `UNBOUND-VARIABLE: The variable *FOO* is unbound.'"
  (format nil "~a: ~a" (debugger-heading-type heading)
          (debugger-heading-report heading)))

(defun heading-title (heading)
  "The panel's title, which says how deep the debugger is."
  (format nil "Debugger — Level ~d" (debugger-heading-level heading)))

(defun forget-restarts (listener)
  "Clear what a panel that is going away leaves behind.  Thread 1.

The controller outlives every panel, so its rows have to go with this one: a
stale list would be answered to the next panel that asks."
  (when listener
    (setf (listener-restarts-panel listener) nil
          (listener-restarts-table listener) nil
          (listener-restarts-invoke listener) nil)
    (let ((controller (getf (listener-retained listener) :restarts-controller)))
      (when controller
        (setf (controller-titles controller) '()
              (controller-views controller) '()
              (controller-cancel-index controller) nil))))
  t)

(defun toplevel-restart-row (&optional (listener *listener*))
  "The row of the restart that returns to the listener's top level, or NIL.
Thread 1.

The panel already worked this out when it was built -- CANCEL-INDEX -- and
this is the same number under a name that says what it is for.  Anything that
wants to take that restart asks for its row rather than assuming one, because
the assumption that would be natural, zero, is wrong for the commonest error
there is: on an unbound variable SBCL puts CONTINUE, USE-VALUE and STORE-VALUE
in front of it, and row 0 is `Retry using *FOO*' -- which retries, and retries."
  (let ((controller (and listener
                         (getf (listener-retained listener) :restarts-controller))))
    (and controller (controller-cancel-index controller))))

(defun cancel-to-top-level (&optional (listener *listener*))
  "Take the restart that returns to the listener's top level, if one is on
offer.  Thread 1.  Returns whether it did."
  (let ((index (toplevel-restart-row listener)))
    (when index
      (choose-restart index)
      t)))

;;; What the debugger calls ------------------------------------------------------

(defun offer-restarts (listener condition restarts
                       &optional backtrace cancel-index (level 1))
  "Show the restarts, from the listener thread.  Never blocks it.

:WAIT NIL, so the listener thread goes straight on to its prompt: the panel and
the prompt are two doors into the same room, and waiting for the panel would
shut the other one."
  (when (and *restarts-panel-enabled* *main-thread-target*)
    (ignore-errors
     ;; Printed HERE, on the listener thread, and handed over as text.
     (let ((heading (condition-heading condition level))
           (rows (restart-rows restarts cancel-index)))
       (on-main-thread ()
         (show-restarts-panel listener heading backtrace rows cancel-index)))))
  restarts)

(defun withdraw-restarts (listener)
  "Take the panel down as the debugger level exits."
  (when *main-thread-target*
    (ignore-errors
     (on-main-thread () (hide-restarts-panel listener))))
  t)
