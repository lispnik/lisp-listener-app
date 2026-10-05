;;;; src/macos/heml.lisp -- heml, the editor, in the listener's application.
;;;;
;;;; heml (github.com/lispnik/heml) is an Emacs-style editor written in Common
;;;; Lisp with a native Cocoa front end.  Loaded into the listener's image and
;;;; started with HEML.COCOA:START-HOSTED, it is one more window of this
;;;; application -- the run loop, the application's delegate and the menu bar
;;;; outside its window stay the listener's -- and its evaluation commands
;;;; evaluate HERE, at the listener's prompt (HEML-EVALUATE-TEXT), so that the
;;;; transcript records each form, an error opens the listener's debugger, and
;;;; the history keeps it.
;;;;
;;;; The ways in:
;;;;
;;;;   - (ed "file.lisp") and (ed 'name) at the prompt: a file, or where NAME
;;;;     is defined, found with sb-introspect;
;;;;   - File > Show Editor, File > Open in Editor..., and Listener > Edit
;;;;     Definition, which types (ed 'symbol-at-the-caret);
;;;;   - and Quit asks heml first, which offers to save what it has changed.
;;;;
;;;; A system of its own, lisp-listener/heml, so that the listener can be
;;;; loaded without heml and everything heml needs.  The application depends on
;;;; it.  Thread 1, except HEML-EVALUATE-TEXT, which heml calls on its own
;;;; thread, and the ED function, which runs on the listener's.

(in-package #:lisp-listener)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-introspect))

;;; Evaluating heml's text at the listener's prompt ------------------------------------

(defun editor-listener-for-heml ()
  "The listener heml's forms go to: the frontmost listener window's.  heml's
own window is the key one when they are sent, so CURRENT-LISTENER would not
do."
  (or (frontmost-listener) *listener* (first *listeners*)))

(defun heml-evaluate-text (text package-name)
  "HEML:*EVALUATE-TEXT-FUNCTION*: type TEXT at the listener's prompt, after
(in-package ...) when heml's buffer is in another package than the prompt.
Called on heml's thread, so the typing is a hop to thread 1."
  (let ((text (string-trim '(#\Space #\Tab #\Newline #\Return) text)))
    (on-main-thread ()
      (let ((listener (editor-listener-for-heml)))
        (when (and listener (plusp (length text)))
          (let ((package (and package-name (find-package package-name))))
            (when (and package (not (eq package (listener-package listener))))
              (type-into-listener listener
                                  (format nil "(in-package ~s)"
                                          (intern (package-name package) "KEYWORD"))
                                  :record t)))
          (type-into-listener listener text :record t)
          ;; Where the answer is, without taking the keyboard from heml.
          (objc:invoke (listener-window listener) "orderFront:" nil))))))

(setf heml:*evaluate-text-function* 'heml-evaluate-text)

;;; Opening heml ----------------------------------------------------------------------

(defun show-editor (&optional file line)
  "Put heml up, visiting FILE at LINE if they are given.  Thread 1."
  (heml.cocoa:start-hosted file :line line))

(defun line-at-character (path offset)
  "The line, counted from one, that character OFFSET of the file PATH is on."
  (with-open-file (in path :external-format :utf-8)
    (let ((line 1))
      (dotimes (i offset line)
        (let ((char (read-char in nil)))
          (unless char (return line))
          (when (char= char #\Newline) (incf line)))))))

(defun definition-location (name)
  "Where NAME -- a symbol -- is defined: its file, and the line there, as two
values; NIL when it was defined somewhere with no file, at the prompt say."
  (dolist (type '(:function :macro :generic-function :class :structure :variable
                  :constant :type :method :setf-expander :compiler-macro))
    (dolist (source (ignore-errors
                     (sb-introspect:find-definition-sources-by-name name type)))
      (let ((path (sb-introspect:definition-source-pathname source))
            (offset (sb-introspect:definition-source-character-offset source)))
        (when (and path (probe-file path))
          (return-from definition-location
            (values (probe-file path) (and offset (line-at-character path offset)))))))))

(defun listener-ed-function (&optional thing)
  "CL:ED, in the listener: heml, in this application, on THING -- a file to
visit, a symbol whose definition to show, or nothing.  Called on the listener's
thread; the window is thread 1's.  First on SB-EXT:*ED-FUNCTIONS*, ahead of
heml's own, which starts an editor of its own and must be on thread 1 to."
  (multiple-value-bind (file line)
      (typecase thing
        (null (values nil nil))
        ((or string pathname) (values (merge-pathnames thing) nil))
        (symbol (or (definition-location thing)
                    (error "No file says where ~s is defined." thing)))
        (t (error "~s is neither a file nor a name to edit." thing)))
    (on-main-thread () (show-editor file line))
    t))

(pushnew 'listener-ed-function sb-ext:*ed-functions*)

;;; The menus ------------------------------------------------------------------------

(objc:define-objc-method ("listenerShowEditor:" :void)
    ((self listener-controller) (sender objc:objc-object-pointer))
  (declare (ignorable sender))
  (handler-case (show-editor)
    (error (condition) (note "listenerShowEditor: ~a" condition))))

(objc:define-objc-method ("listenerOpenInEditor:" :void)
    ((self listener-controller) (sender objc:objc-object-pointer))
  (declare (ignorable sender))
  (handler-case
      (let ((panel (objc:invoke "NSOpenPanel" "openPanel")))
        (objc:invoke panel "setAllowsMultipleSelection:" nil)
        (objc:invoke panel "setCanChooseDirectories:" nil)
        (objc:invoke panel "setMessage:" "Choose a file to edit.")
        (objc:invoke panel "setPrompt:" "Edit")
        (when (= 1 (objc:invoke panel "runModal"))       ; NSModalResponseOK
          (let ((url (objc:invoke (objc:invoke panel "URLs") "firstObject")))
            (show-editor (objc:ns-string-to-string (objc:invoke url "path"))))))
    (error (condition) (note "listenerOpenInEditor: ~a" condition))))

(objc:define-objc-method ("listenerEditDefinition:" :void)
    ((self listener-controller) (sender objc:objc-object-pointer))
  (declare (ignorable sender))
  ;; The symbol at the caret, typed as (ed 'symbol) at the prompt: the
  ;; transcript says what was looked for, and a name with no file says so
  ;; there too, as an error.
  (handler-case
      (let ((listener (current-listener)))
        (when listener
          (let ((token (completion-token (listener-view-object listener)
                                         (listener-view listener))))
            (when (and token (plusp (length token)))
              (type-into-listener listener (format nil "(ed '~a)" token) :record t)))))
    (error (condition) (note "listenerEditDefinition: ~a" condition))))

(setf *editor-menu-items*
      '((:file ("Show Editor" "listenerShowEditor:" "E")
               ("Open in Editor…" "listenerOpenInEditor:" "O"))
        (:listener ("Edit Definition" "listenerEditDefinition:" "e"))))

;;; Quitting -------------------------------------------------------------------------

(defconstant +terminate-cancel+ 0)
(defconstant +terminate-now+ 1)

;;; heml first: a file it has changed is offered for saving, as C-x C-c offers
;;; it, and this quit is cancelled until heml has finished.
(objc:define-objc-method ("applicationShouldTerminate:" (:unsigned :long))
    ((self listener-application-delegate) (application objc:objc-object-pointer))
  (declare (ignorable application))
  (handler-case (if (heml.cocoa:hosted-quit-ok-p) +terminate-now+ +terminate-cancel+)
    (error (condition)
      (note "applicationShouldTerminate: ~a" condition)
      +terminate-now+)))
