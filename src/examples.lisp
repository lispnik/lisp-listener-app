;;;; src/examples.lisp -- a few short programs that ship inside the image.
;;;;
;;;; (examples) lists them, (example "spiral") runs one, and (example-source
;;;; "spiral") prints it to be read and changed.  The Examples menu on the Mac
;;;; and the Try key on a phone type the second of those at the prompt, so the
;;;; transcript shows how it was done and the history has it.
;;;;
;;;; They live in examples/*.lisp, as files, so that they are ordinary Lisp to
;;;; edit, to load and to check -- and they are read into the image WHEN THIS
;;;; FILE IS COMPILED.  An app has no source tree beside it, least of all on a
;;;; phone; a string in the image is the only place they can be found from.
;;;; lisp-listener.asd names each as a static file ahead of this one, which is
;;;; what makes ASDF compile this again when an example changes.
;;;;
;;;; Each is run by reading and evaluating its forms on the listener thread,
;;;; with *PACKAGE* bound to CL-USER, so what an example defines -- SPIRAL,
;;;; ROSE, SNAKE -- is there to be called again with other arguments.

(in-package #:lisp-listener)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *example-names* '("hello" "spiral" "rose" "tree" "life" "snake")
    "The examples, in the order the menu lists them.  A new one is a file in
examples/, a name here, and a static file in lisp-listener.asd.")

  (defun example-file-text (path)
    (with-open-file (in path :external-format :utf-8)
      (with-output-to-string (out)
        (loop for line = (read-line in nil nil)
              while line
              do (write-line line out)))))

  (defun parse-example-header (name text)
    "The title and the description, from a first line `;;; Title -- the rest.'"
    (let* ((line (subseq text 0 (or (position #\Newline text) (length text))))
           (start (or (position #\; line :test-not #'char=) (length line)))
           (rest (string-trim " " (subseq line start)))
           (dash (search " -- " rest)))
      (if dash
          (values (subseq rest 0 dash)
                  (string-capitalize (subseq rest (+ dash 4)) :end 1))
          (values (string-capitalize name) rest))))

  (defun read-example-files ()
    "Every example as (NAME TITLE DESCRIPTION SOURCE), read from examples/
beside src/ -- at compile time, or at load time when this file is loaded as
source."
    (let* ((here (or *compile-file-truename* *load-truename*
                     (error "examples: nowhere to read them from.")))
           (directory (append (butlast (pathname-directory here)) '("examples"))))
      (loop for name in *example-names*
            for text = (example-file-text
                        (make-pathname :name name :type "lisp" :version nil
                                       :directory directory :defaults here))
            collect (multiple-value-bind (title description)
                        (parse-example-header name text)
                      (list name title description text))))))

(defmacro embedded-examples ()
  ;; A macro and not #. -- the syntax check reads this file with
  ;; *READ-SUPPRESS*, on a machine where the path need not resolve.
  `',(read-example-files))

(defparameter *examples* (embedded-examples)
  "The examples, each (NAME TITLE DESCRIPTION SOURCE).  Strings, in the image.")

(defun example-name (entry) (first entry))
(defun example-title (entry) (second entry))
(defun example-description (entry) (third entry))
(defun example-text (entry) (fourth entry))

(defun find-example (name)
  "The example called NAME -- a string or a symbol, in any case -- or an error
that says what there is."
  (or (assoc (string name) *examples* :test #'string-equal)
      (error "There is no example called ~a.  There are: ~{~a~^, ~}."
             name (mapcar #'example-name *examples*))))

(defun example-form (name)
  "What is typed at the prompt to run the example NAME."
  (format nil "(example ~s)" (example-name (find-example name))))

(defun examples ()
  "List the examples that came with the listener."
  (format t "~&")
  (dolist (entry *examples*)
    (format t "  ~8a ~a~%" (example-name entry) (example-description entry)))
  (format t "Run one with (example \"~a\"), and read it with (example-source \"~:*~a\").~%"
          (example-name (second *examples*)))
  (values))

(defun example-source (name)
  "Print the example NAME, to be read, copied and changed."
  (format t "~&~a" (example-text (find-example name)))
  (fresh-line)
  (values))

(defun example (name)
  "Run the example NAME, and answer what its last form did.

Its forms are read in CL-USER and evaluated one after another, as if typed, so
whatever it defines stays defined: after (example \"spiral\") there is a SPIRAL
to call with an angle of your own."
  (let ((entry (find-example name))
        (*package* (find-package "COMMON-LISP-USER"))
        (results '()))
    (with-input-from-string (in (example-text entry))
      (loop for form = (read in nil in)
            until (eq form in)
            do (setf results (multiple-value-list (eval form)))))
    (values-list results)))

(defun run-example-in-listener (listener name)
  "Type (example \"NAME\") at LISTENER's prompt.  Thread 1: what the Examples
menu and the Try key do.  Nothing is evaluated here."
  (when listener
    (type-into-listener listener (example-form name) :record t)))

(defun open-examples-popup (&optional (listener (current-listener)))
  "List the examples in the history's list, each as the form that runs it.
Thread 1.  Choosing one puts it at the prompt, as choosing a line of history
does: Return runs it.  What a phone has instead of a menu bar."
  (let ((controller (listener-history-controller listener)))
    (when controller
      (setf (history-controller-listener controller) listener
            (history-controller-lines controller)
            (mapcar (lambda (entry) (example-form (example-name entry))) *examples*))
      (refilter-history controller "")
      (show-history-popup listener)
      t)))
