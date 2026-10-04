;;;; src/config.lisp -- init.lisp, so a setting outlives the launch.
;;;;
;;;; Beside the history, in the directory src/history.lisp already resolves per
;;;; platform: ~/Library/Application Support/Lisp Listener/ on the Mac, and the
;;;; app's own Documents/ on iOS.  One file, loaded once, before the first
;;;; listener's thread starts, so what it sets is in force for the banner
;;;; onwards.
;;;;
;;;; A BROKEN INIT FILE MAY NOT STOP THE LISTENER.  It is the one file here that
;;;; somebody edits by hand, which makes it the one most likely to be wrong, and
;;;; a program that will not start because of it is a program that cannot be
;;;; used to fix it.  So every condition is caught and reported -- to the log,
;;;; and into the transcript as a note once there is one -- and the listener
;;;; starts anyway.

(in-package #:lisp-listener)

(defvar *init-file-loaded* nil
  "What LOAD-INIT-FILE did, for the transcript to report: NIL, :NONE, :LOADED,
or (:FAILED . report).")

(defun init-file-path ()
  "Where init.lisp is, whether or not it is there; NIL with no directory."
  (ignore-errors
   (let ((directory (or *history-directory* (history-directory))))
     (when directory
       (merge-pathnames "init.lisp" directory)))))

(defparameter *init-file-template*
  ";;;; init.lisp -- loaded each time Lisp Listener starts, before the first prompt.
;;;;
;;;; Read in the LISP-LISTENER package, which is where the settings are.  A
;;;; form that signals is reported in the transcript, and the listener starts
;;;; anyway.  For example:
;;;;
;;;;   (setf (preference :font-size) 15)          ; what Settings sets, too
;;;;   (setf (paredit-key \"C-(\") 'slurp-backward)  ; rebind a paredit key
;;;;   (setf *paren-highlight-enabled* nil)
;;;;
;;;; And anything else you want in every session -- in your own package:
;;;;
;;;;   (in-package :cl-user)
;;;;   (defun square (x) (* x x))

"
  "What a new init.lisp says: how it is read, and what it might hold.")

(defun lisp-listener:init-file ()
  "The pathname of init.lisp -- the file loaded each time the listener starts --
made, with a few lines saying what it is for, if there is none yet."
  (let ((path (or (init-file-path) (error "There is no directory to keep init.lisp in."))))
    (unless (probe-file path)
      (ensure-directories-exist path)
      (with-open-file (out path :direction :output :if-does-not-exist :create
                                :external-format :utf-8)
        (write-string *init-file-template* out)))
    path))

(defun load-init-file ()
  "Load init.lisp, if there is one.  Returns what happened, and never signals.

Read in this package, because that is what it will be setting: *PAREDIT-KEYS*,
*PAREDIT-ENABLED*, *FONT-SIZE*.  A file may say (in-package ...) itself."
  (setf *init-file-loaded*
        (let ((path (init-file-path)))
          (cond
            ((null path) :none)
            ((not (probe-file path)) :none)
            (t (handler-case
                   (let ((*package* (find-package "LISP-LISTENER")))
                     (load path :external-format :utf-8)
                     (note "loaded ~a" (namestring path))
                     :loaded)
                 (error (condition)
                   (let ((report (report-condition condition)))
                     (note "init file ~a: ~a" (namestring path) report)
                     (cons :failed report)))))))))

(defun report-init-file (listener)
  "Say in the transcript what the init file did, when there is anything to say.

Only a failure is worth a line: a listener that loaded its init file silently
is the ordinary case, and saying so every time would be noise above every
banner."
  (let ((outcome *init-file-loaded*))
    (when (and listener (consp outcome) (eq (car outcome) :failed))
      (let ((stream (listener-output listener)))
        (with-output-kind (stream :error)
          (format stream "~&; init.lisp: ~a~%" (cdr outcome)))))
    outcome))
