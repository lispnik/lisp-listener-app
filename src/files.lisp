;;;; src/files.lisp -- loading files into a listener, and saving its transcript.
;;;;
;;;; File > Open... and a file dropped on the window both end here, and both
;;;; LOAD by typing `(load "/path/to/file.lisp")' at the prompt, as a person
;;;; would: the transcript records what was loaded, its output and its errors
;;;; land where everything else does, an error in the file opens the debugger,
;;;; and the line goes into the history to be run again.  Nothing is loaded on
;;;; thread 1, which must never evaluate.
;;;;
;;;; The front end supplies the panels and the drop; this file is what they do,
;;;; and so what `make test' covers.

(in-package #:lisp-listener)

(defparameter *loadable-file-types* '("lisp" "lsp" "cl" "l" "asd" "fasl")
  "The file types a drop or Open... loads.  Anything else dropped on the window
is left to the text view, which inserts its path.")

(defun loadable-file-p (path)
  (let ((type (pathname-type (pathname path))))
    (and type (member type *loadable-file-types* :test #'string-equal) t)))

(defun load-form (path)
  "The line typed at the prompt to load PATH: `(load \"/path/to/file.lisp\")'."
  (with-standard-io-syntax
    (let ((*print-readably* nil))
      (format nil "(load ~s)" (namestring path)))))

(defun load-files-into-listener (listener paths)
  "Load each of PATHS that is a Lisp file, in order, at LISTENER's prompt.
Thread 1.  Answers how many it typed.

Each is its own line, so an error in one opens the debugger with the others
still queued behind it -- and taking the top-level restart there goes on to
the next, which is what typing them one after another would do too."
  (let ((count 0))
    (dolist (path paths count)
      (when (loadable-file-p path)
        (type-into-listener listener (load-form path) :record t)
        (incf count)))))

(defun transcript-text-of (listener)
  "Everything in LISTENER's transcript, as a string.  Thread 1."
  (let ((pointer (listener-view listener)))
    (transcript-substring pointer 0 (transcript-length pointer))))

(defun save-transcript (listener path)
  "Write LISTENER's transcript to PATH, as plain UTF-8 text.  Thread 1.
Answers PATH.  The colours are the window's; the words are the record."
  (with-open-file (out path :direction :output :if-exists :supersede
                            :external-format :utf-8)
    (write-string (transcript-text-of listener) out))
  path)
