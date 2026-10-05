;;;; src/editor.lisp -- an editor made of the listener's own editing.
;;;;
;;;; A file in a text view, written with everything the prompt has: paredit,
;;;; the indenter, completion, the paren tint, what a call takes.  All of that
;;;; works on the region from VIEW-INPUT-START to the end, so an editor is the
;;;; same LISTENER-TEXT-VIEW with that start at 0 and its ROLE :EDITOR -- and
;;;; the few things only a prompt does (Return submits, the arrows walk the
;;;; history, output arrives) ask the role first.
;;;;
;;;; Evaluating is the LISTENER's: a form is typed at its prompt with
;;;; TYPE-INTO-LISTENER, so the transcript records it, an error opens the
;;;; debugger, and the history keeps it -- preceded by (in-package ...) when
;;;; the file is in another package than the prompt.
;;;;
;;;; The window or sheet that holds an editor is the front end's: on iOS
;;;; src/ios/editor-sheet.lisp.  On the Mac the editor is heml.

(in-package #:lisp-listener)

(defstruct (editor (:constructor %make-editor))
  (path nil)                            ; a pathname
  (saved-text "")                       ; what is on disk, as last read or written
  view                                  ; the LISTENER-TEXT-VIEW object
  pointer                               ; and its Objective-C half
  listener)                             ; where its forms are evaluated

;;; Reading the buffer -------------------------------------------------------------

(defun top-level-form-at (text offset)
  "(values START END) of the top-level form OFFSET is in -- or, between forms,
the one just before it, which is where the caret is after one has been typed.
NIL in a buffer with no forms before or around OFFSET."
  (let ((before nil))
    (dolist (span (sexp-spans text 0) (and before (values (car before) (cdr before))))
      (cond ((<= (car span) offset (cdr span))
             (return (values (car span) (cdr span))))
            ((< (cdr span) offset) (setf before span))
            (t (return (and before (values (car before) (cdr before)))))))))

(defun in-package-name (form)
  "The package (in-package NAME) names, as a string, or NIL for any other form."
  (and (consp form)
       (symbolp (first form))
       (string= (symbol-name (first form)) "IN-PACKAGE")
       (let ((name (second form)))
         (cond ((stringp name) name)
               ((symbolp name) (symbol-name name))))))

(defun buffer-package-at (text offset)
  "The package the last (in-package ...) before OFFSET in TEXT names, if it
exists -- the package the form at OFFSET is read in -- or NIL.

Each top-level form is only looked at, never evaluated: read with *READ-EVAL*
off, in a package of its own, so that reading the file interns nothing
anywhere that matters."
  (let ((name nil)
        (scratch (or (find-package "LISP-LISTENER-EDITOR-READ")
                     (make-package "LISP-LISTENER-EDITOR-READ" :use '()))))
    ;; Those ENDED before OFFSET: inside the (in-package ...) itself, it is
    ;; not yet in force.
    (dolist (span (sexp-spans text 0))
      (when (> (cdr span) offset) (return))
      (let ((form (ignore-errors
                   (let ((*read-eval* nil)
                         (*package* scratch))
                     (read-from-string text t nil :start (car span) :end (cdr span))))))
        (let ((named (in-package-name form)))
          (when named (setf name named)))))
    (and name (find-package (string-upcase name)))))

(defun view-reading-package (view pointer &optional (listener *listener*))
  "The package a symbol at the caret in VIEW is read in: an editor's file's
own, from its (in-package ...); otherwise the listener's."
  (or (and view (eq (view-role view) :editor)
           (let* ((text (transcript-substring pointer 0 (transcript-length pointer)))
                  (caret (or (caret-index pointer) 0)))
             (buffer-package-at text (utf-16-offset->index text caret))))
      (listener-completion-package listener)))

(defun editor-text (editor)
  (let ((pointer (editor-pointer editor)))
    (transcript-substring pointer 0 (transcript-length pointer))))

(defun editor-dirty-p (editor)
  "Whether the buffer says something other than the file."
  (string/= (editor-text editor) (editor-saved-text editor)))

;;; Evaluating ---------------------------------------------------------------------

(defun editor-evaluate (editor text &key (offset 0))
  "Type TEXT at the editor's listener's prompt, to be read and evaluated there
-- after (in-package ...) when the file, at OFFSET, is in another package than
the prompt is.  Thread 1.  True if anything was typed."
  (let* ((listener (editor-listener editor))
         (file-package (buffer-package-at (editor-text editor) offset))
         (prompt-package (and listener (listener-package listener))))
    (when (and listener (plusp (length (string-trim '(#\Space #\Tab #\Newline) text))))
      (when (and file-package (not (eq file-package prompt-package)))
        (type-into-listener listener
                            (format nil "(in-package ~s)"
                                    (intern (package-name file-package) "KEYWORD"))
                            :record t))
      (type-into-listener listener text :record t)
      t)))

(defun editor-evaluate-form (editor)
  "Evaluate the top-level form the caret is in, or the one just before it."
  (let* ((text (editor-text editor))
         (caret (utf-16-offset->index text (or (caret-index (editor-pointer editor)) 0))))
    (multiple-value-bind (start end) (top-level-form-at text caret)
      (when start
        (editor-evaluate editor (subseq text start end) :offset start)))))

(defun editor-load (editor)
  "Save the file, and load it at the prompt."
  (editor-save editor)
  (when (editor-listener editor)
    (load-files-into-listener (editor-listener editor) (list (editor-path editor)))))

;;; Files --------------------------------------------------------------------------

(defun read-file-text (path)
  (with-open-file (in path :external-format :utf-8)
    (let* ((string (make-string (file-length in)))
           (end (read-sequence string in)))
      (subseq string 0 end))))

(defun editor-open (editor path)
  "Read PATH into EDITOR's view -- empty if there is no such file yet."
  (let ((text (if (probe-file path) (read-file-text path) "")))
    (setf (editor-path editor) (pathname path)
          (editor-saved-text editor) text)
    (objc:invoke (editor-pointer editor) "setText:" text)
    (objc:invoke (editor-pointer editor) "setSelectedRange:" (cons 0 0))
    editor))

(defun editor-save (editor &optional (path (editor-path editor)))
  "Write the buffer to PATH, and remember that it is what the file says."
  (let ((text (editor-text editor)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create :external-format :utf-8)
      (write-string text out))
    (setf (editor-path editor) (pathname path)
          (editor-saved-text editor) text)
    path))
