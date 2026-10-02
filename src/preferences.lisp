;;;; src/preferences.lisp -- the settings a window can change, kept between launches.
;;;;
;;;; init.lisp is for someone who will write Lisp to configure a Lisp, and it
;;;; still has the last word: it is loaded after this.  These are the handful of
;;;; switches worth a checkbox -- paredit, the paren tint, the indenter, the
;;;; debugger pane, the size of the type -- and what the application remembers
;;;; for itself, such as where its windows were.
;;;;
;;;; One file, preferences.lisp-expr, beside the history and for the same
;;;; reason in the same directory: a property list, printed readably and read
;;;; with *READ-EVAL* off.  Not NSUserDefaults -- this way it is one mechanism
;;;; on the Mac and on a phone, `make test' covers it, and a driven run, whose
;;;; history directory is its own, starts from the defaults without being told.
;;;;
;;;; A preference that cannot be read is the default, and a file that cannot be
;;;; written costs the setting and nothing else.

(in-package #:lisp-listener)

(defvar *reopen-windows* t
  "Whether the application opens the windows it had when it was last quit,
where they were.")

(defparameter *preferences*
  '((:paredit *paredit-enabled* boolean)
    (:paren-highlight *paren-highlight-enabled* boolean)
    (:auto-indent *auto-indent-enabled* boolean)
    (:debugger-pane *restarts-panel-enabled* boolean)
    (:reopen-windows *reopen-windows* boolean)
    (:font-size *font-size* font-size))
  "The settings: a key, the variable that holds it, and what it may be.")

(defvar *remembered* '()
  "What the application keeps for itself in the same file, as a plist: where
the windows were.  Not variables, so not in *PREFERENCES*.")

(defparameter *font-size-range* '(9 . 36))

(defun preferences-file ()
  (ignore-errors
   (let ((directory (or *history-directory* (history-directory))))
     (when directory
       (merge-pathnames "preferences.lisp-expr" directory)))))

(defun valid-preference (kind value)
  "VALUE as a setting of KIND, and whether it is one."
  (ecase kind
    (boolean (values (and value t) (member value '(t nil))))
    (font-size (if (and (realp value)
                        (<= (car *font-size-range*) value (cdr *font-size-range*)))
                   (values (float value 1d0) t)
                   (values nil nil)))))

(defun read-preferences ()
  "The file's plist, or NIL: when there is none, or it is not a plist."
  (ignore-errors
   (let ((path (preferences-file)))
     (when (and path (probe-file path))
       (with-open-file (in path :external-format :utf-8)
         (let ((form (with-standard-io-syntax
                       (let ((*read-eval* nil)
                             (*package* (find-package "LISP-LISTENER")))
                         (read in nil nil)))))
           (and (listp form) (evenp (length form)) form)))))))

(defun load-preferences ()
  "Set each setting from the file, where the file has it and it is sound.
Answers how many it set.  Before init.lisp, which may then overrule it."
  (let ((plist (read-preferences))
        (count 0))
    (loop for (key variable kind) in *preferences*
          for found = (member key plist)
          do (when found
               (multiple-value-bind (value ok) (valid-preference kind (second found))
                 (when ok
                   (setf (symbol-value variable) value)
                   (incf count)))))
    (setf *remembered*
          (loop for (key value) on plist by #'cddr
                unless (assoc key *preferences*)
                  append (list key value)))
    count))

(defun save-preferences ()
  "Write every setting, and what is remembered, to the file.  Never signals."
  (handler-case
      (let ((path (preferences-file)))
        (when path
          (ensure-directories-exist path)
          (with-open-file (out path :direction :output :if-exists :supersede
                                    :external-format :utf-8)
            (with-standard-io-syntax
              (let ((*package* (find-package "LISP-LISTENER"))
                    (*print-readably* nil))
                (format out "(~{~s ~s~^~% ~})~%"
                        (append (loop for (key variable) in *preferences*
                                      append (list key (symbol-value variable)))
                                *remembered*)))))
          path))
    (error (condition)
      (note "preferences: ~a" condition)
      nil)))

(defun preference (key)
  "The setting KEY -- :paredit, :paren-highlight, :auto-indent, :debugger-pane,
:reopen-windows or :font-size.  SETF changes it, for good:

    (setf (lisp-listener:preference :font-size) 16)"
  (let ((entry (assoc key *preferences*)))
    (unless entry
      (error "There is no preference ~s.  There are: ~{~s~^, ~}."
             key (mapcar #'first *preferences*)))
    (symbol-value (second entry))))

(defun (setf preference) (value key)
  (let ((entry (assoc key *preferences*)))
    (unless entry
      (error "There is no preference ~s.  There are: ~{~s~^, ~}."
             key (mapcar #'first *preferences*)))
    (multiple-value-bind (sound ok) (valid-preference (third entry) value)
      (unless ok
        (error "~s is not a value for ~s~@[; a size is from ~d to ~d~]."
               value key
               (and (eq (third entry) 'font-size) (car *font-size-range*))
               (cdr *font-size-range*)))
      (setf (symbol-value (second entry)) sound)
      (when (eq key :font-size)
        (apply-font-size))
      (save-preferences)
      sound)))

(defun remembered (key)
  (getf *remembered* key))

(defun (setf remembered) (value key)
  (setf (getf *remembered* key) value)
  (save-preferences)
  value)

(defun preferences-changed ()
  "A switch changed: what depends on it follows.  Thread 1; both front ends'
settings call it.  The paren tint is on screen, so switching it off has to
take the tint that is there away."
  (dolist (listener *listeners*)
    (let ((view (listener-view-object listener))
          (pointer (listener-view listener)))
      (when (and view pointer)
        (refresh-paren-highlight view pointer)))))

;;; The size of the type ----------------------------------------------------------

(defun refont-transcript (pointer)
  "Set everything in the transcript POINTER in the current size.  Thread 1.
The colours are attributes of their own and stay as they are."
  (let ((length (transcript-length pointer)))
    (when (plusp length)
      (objc:invoke (transcript-storage pointer) "addAttribute:value:range:"
                   (%ns-string-constant "NSFontAttributeName")
                   (transcript-font *font-size*)
                   (cons 0 length)))
    (apply-typing-attributes pointer)))

(defun apply-font-size ()
  "Put *FONT-SIZE* into force in every listener: what is there already and
what is typed next.  From any thread; the views are thread 1's."
  (when *main-thread-target*
    (on-main-thread ()
      ;; The attribute dictionaries are cached per kind, with the font in them.
      (reset-transcript-attributes)
      (dolist (listener *listeners*)
        (let ((pointer (listener-view listener)))
          (when pointer
            (refont-transcript pointer))))))
  *font-size*)

(defun change-font-size (delta)
  "Make the type DELTA points bigger, within reason, and remember it."
  (let ((size (max (car *font-size-range*)
                   (min (cdr *font-size-range*) (+ *font-size* delta)))))
    (setf (preference :font-size) size)))
