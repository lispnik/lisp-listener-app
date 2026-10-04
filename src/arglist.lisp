;;;; src/arglist.lisp -- what the form being typed takes.
;;;;
;;;; With the caret inside (mapcar #'1+ |, the listener says
;;;;
;;;;     (mapcar function list &rest more-lists)
;;;;
;;;; and which of those the caret is on: LIST.  It is asked of the live image
;;;; -- the lambda list of whatever function or macro the operator names now,
;;;; DEFUN'd a moment ago included -- and of a table for the special
;;;; operators, which have no lambda list to ask.  Nothing is evaluated and
;;;; nothing is interned, so it is safe on thread 1, on every keystroke.
;;;;
;;;; The innermost form that is a call is the one described: inside
;;;; (let ((x |, the binding list is no call, and LET is.
;;;;
;;;; Where the hint is shown is the front end's (SHOW-ARGLIST-HINT): the
;;;; window's subtitle on the Mac, a line over the keys on iOS.

(in-package #:lisp-listener)

(defparameter *special-operator-arglists*
  '((if test then &optional else)
    (let bindings &body body)
    (let* bindings &body body)
    (progn &rest forms)
    (setq &rest pairs)
    (quote object)
    (function name)
    (block name &body body)
    (return-from name &optional value)
    (flet definitions &body body)
    (labels definitions &body body)
    (macrolet definitions &body body)
    (symbol-macrolet bindings &body body)
    (tagbody &rest tags-and-statements)
    (go tag)
    (the type form)
    (unwind-protect protected-form &body cleanup-forms)
    (catch tag &body body)
    (throw tag result)
    (multiple-value-call function &rest forms)
    (multiple-value-prog1 first-form &body forms)
    (progv symbols values &body body)
    (eval-when situations &body body)
    (locally &body body)
    (load-time-value form &optional read-only-p))
  "The special operators' lambda lists, which no implementation will say.")

(defparameter *recorded-arglists* (recorded-cl-arglists)
  "COMMON-LISP's lambda lists as the compiling image knew them, for an image
that cannot say at run time -- ECL on iOS.  NIL where it can.")

(defun operator-lambda-list (symbol)
  "SYMBOL's lambda list, and true if it is known; NIL and NIL for a symbol
that names no function or names one that will not say."
  (let ((special (assoc symbol *special-operator-arglists*))
        (recorded (assoc symbol *recorded-arglists*)))
    (cond (special (values (rest special) t))
          ((macro-function symbol)
           (let ((list (ignore-errors (macro-lambda-list symbol))))
             (cond (list (values list t))
                   (recorded (values (cdr recorded) t))
                   (t (values nil t)))))
          ((fboundp symbol)
           (multiple-value-bind (list known) (function-arglist (fdefinition symbol))
             (cond ((and known (or list (not recorded))) (values list t))
                   (recorded (values (cdr recorded) t))
                   (t (values nil nil)))))
          (t (values nil nil)))))

(defun lambda-list-argument (lambda-list index)
  "Which element of LAMBDA-LIST the argument at INDEX (0 the first) goes to, as
a position in the list, or NIL: past &KEY, where it depends on the keyword
before it rather than on where it is."
  (let ((position 0) (argument 0) (rest nil))
    (loop for cell on lambda-list
          for item = (car cell)
          do (cond ((member item '(&whole &environment))
                    ;; Each takes the variable after it, which is no argument.
                    (pop cell) (incf position))
                   ((member item '(&rest &body)) (setf rest (1+ position)))
                   ((member item '(&key &allow-other-keys &aux)) (return))
                   ((member item lambda-list-keywords))
                   ((not rest)
                    (when (= argument index) (return-from lambda-list-argument position))
                    (incf argument)))
             (incf position)
             (when (atom (cdr cell)) (return)))
    rest))

(defun lambda-list-text (name lambda-list mark package)
  "NAME and LAMBDA-LIST as one line, lowercase, as read in PACKAGE; and the
start and end in it of element MARK of the lambda list, or NIL.

Printed without escapes, so without package prefixes: a parameter's package
is the implementation's business -- SBCL's MAPCAR takes SB-IMPL::FUNCTION --
and the name is all a hint needs."
  (let ((*package* package)
        (*print-case* :downcase)
        (*print-escape* nil)
        (*print-pretty* nil)
        (*print-length* 8)
        (*print-level* 3)
        (start nil) (end nil))
    (values
     (with-output-to-string (out)
       (format out "(~a" name)
       (loop for cell on lambda-list
             for position from 0
             do (write-char #\Space out)
                (when (eql position mark) (setf start (file-position out)))
                (princ (car cell) out)
                (when (eql position mark) (setf end (file-position out)))
                (unless (listp (cdr cell))
                  ;; A dotted lambda list: (a b . rest).
                  (format out " . ~a" (cdr cell))))
       (write-char #\) out))
     start end)))

(defun call-at (text offset package)
  "The innermost form around OFFSET in TEXT that calls something with a lambda
list to tell: its operator's symbol, the lambda list, and which argument the
caret is on (0 the first, -1 on the operator itself), as three values."
  (multiple-value-bind (open quoted) (innermost-open-paren text offset)
    ;; A string, a comment or a |symbol| still open at the caret is no place
    ;; for a hint.  Asked of the text up to the caret and a space: the scanner
    ;; takes an unterminated string at the very end for one that ends there.
    (unless (code-position-p (concatenate 'string (subseq text 0 offset) " x") offset)
      (setf quoted t))
    (loop with *indent-package* = package
          while (and open (not quoted))
          do (let* ((elements (list-elements text open offset))
                    (operator (first elements)))
               (when operator
                 (let ((symbol (token-symbol (subseq text (car operator) (cdr operator)))))
                   (when symbol
                     (multiple-value-bind (lambda-list known) (operator-lambda-list symbol)
                       (when known
                         (let* ((last (first (last elements)))
                                ;; On an element, or in the space after it.
                                (on-last (<= offset (cdr last)))
                                (index (- (length elements) (if on-last 2 1))))
                           (return (values symbol lambda-list index)))))))))
             (setf open (and (plusp open) (innermost-open-paren text open))))))

(defun arglist-hint (text offset package)
  "The hint for the caret at OFFSET in TEXT, the input being typed: the call's
lambda list as one line, and the start and end in it of the argument the caret
is on -- or NIL where the caret is in no call that can be described."
  (multiple-value-bind (symbol lambda-list index) (call-at text offset package)
    (when symbol
      (lambda-list-text symbol lambda-list
                        (and (>= index 0) (lambda-list-argument lambda-list index))
                        package))))

(defun refresh-arglist-hint (view pointer)
  "Say what the call around the caret takes, or say nothing.  Thread 1, on
every selection change; a hint is decoration, and may not take the keystroke
down with it."
  (handler-case
      (let ((listener (listener-for-view-object view)))
        (when listener
          (multiple-value-bind (hint start end)
              (and *arglist-hints-enabled*
                   (let ((input-start (view-input-start view))
                         (caret (caret-index pointer)))
                     (when (and input-start caret (>= caret input-start))
                       (let ((text (pending-input view pointer)))
                         (arglist-hint text (utf-16-offset->index text (- caret input-start))
                                       (listener-completion-package listener))))))
            ;; Told only of a change: this runs on every caret movement.
            (let ((shown (list hint start end)))
              (unless (equal shown (getf (listener-retained listener) :arglist-hint))
                (setf (getf (listener-retained listener) :arglist-hint) shown)
                (show-arglist-hint listener hint start end))))))
    (error (condition)
      (note "arglist hint: ~a" condition)
      nil))
  t)
