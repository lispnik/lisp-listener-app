;;;; src/macos/preferences-window.lisp -- Settings: six switches, a size, and
;;;; the way to init.lisp.
;;;;
;;;; The Mac's window onto src/preferences.lisp.  Each control changes its
;;;; setting at once, through (SETF PREFERENCE), which is also what saves it;
;;;; there is no OK and nothing to apply.  Everything here can equally be set
;;;; in init.lisp, which is loaded later and so wins at the next launch -- the
;;;; window shows what is in force now, whoever set it.
;;;;
;;;; Thread 1, all of it.

(in-package #:lisp-listener)

(defparameter *preferences-width* 380d0)
(defparameter *preferences-row* 28d0)
(defparameter *preferences-margin* 20d0)

(defparameter *preference-switches*
  '((:paredit "Balance parentheses and quotes as they are typed")
    (:paren-highlight "Tint the parenthesis at the caret and its partner")
    (:arglist-hints "Show what the call being typed takes, under the transcript")
    (:auto-indent "Indent the new line that Option-Return starts")
    (:debugger-pane "Dock the debugger under the transcript")
    (:reopen-windows "Reopen windows where they were"))
  "The checkboxes, top to bottom: the preference and what it says.")

(defparameter *preference-font-sizes* '(10 11 12 13 14 15 16 18 20 24 28))

(defvar *preferences-window* nil
  "The Settings window, or NIL until it is first asked for.  Made at run time.")

(defvar *preferences-controller* nil
  "The controls' target, held because a control does not retain its target.")

(defvar *preference-controls* '()
  "The controls, as (KEY . POINTER): a checkbox for each switch, and the size's
pop-up under :FONT-SIZE.  Each is retained by its superview.")

(objc:define-objc-class preferences-controller ()
  ()
  (:objc-class-name "LispListenerPreferencesController"))

(defun font-size-title (size)
  (if (= size (round size))
      (format nil "~d" (round size))
      (format nil "~,1f" size)))

(objc:define-objc-method ("preferenceToggled:" :void)
    ((self preferences-controller) (sender objc:objc-object-pointer))
  (handler-case
      (let ((key (car (find sender *preference-controls*
                            :key #'cdr :test #'same-objc-object-p))))
        (when key
          (setf (preference key) (= 1 (objc:invoke sender "state")))
          (preferences-changed)))
    (error (condition) (note "preferenceToggled: ~a" condition))))

(objc:define-objc-method ("preferenceFontSize:" :void)
    ((self preferences-controller) (sender objc:objc-object-pointer))
  (handler-case
      (let ((size (ignore-errors
                   (let ((*read-eval* nil))
                     (read-from-string
                      (objc:ns-string-to-string
                       (objc:invoke sender "titleOfSelectedItem")))))))
        (when (realp size)
          (setf (preference :font-size) size)))
    (error (condition) (note "preferenceFontSize: ~a" condition))))

;;; init.lisp opens in whatever edits Lisp here, or in TextEdit when nothing
;;; claims the type; made first, with a few lines saying what it is for.
(defun open-init-file ()
  "Open init.lisp in an editor, making it if there is none.  Thread 1."
  (let* ((path (namestring (init-file)))
         (url (objc:invoke "NSURL" "fileURLWithPath:" path))
         (workspace (objc:invoke "NSWorkspace" "sharedWorkspace")))
    (or (objc:invoke-bool workspace "openURL:" url)
        (objc:invoke-bool workspace "openFile:withApplication:" path "TextEdit"))))

(objc:define-objc-method ("preferenceEditInitFile:" :void)
    ((self preferences-controller) (sender objc:objc-object-pointer))
  (declare (ignorable sender))
  (handler-case (open-init-file)
    (error (condition) (note "preferenceEditInitFile: ~a" condition))))

(defun build-preferences-window ()
  (let* ((rows (+ 2 (length *preference-switches*)))
         (width *preferences-width*)
         (height (+ (* 2 *preferences-margin*) (* rows *preferences-row*)))
         (controller (make-instance 'preferences-controller))
         (target (objc:objc-object-pointer controller))
         (window (objc:invoke (objc:invoke "NSWindow" "alloc")
                              "initWithContentRect:styleMask:backing:defer:"
                              (vector 0d0 0d0 width height)
                              (logior +ns-window-style-titled+ +ns-window-style-closable+)
                              +ns-backing-store-buffered+ nil))
         (content (objc:invoke window "contentView"))
         (y (- height *preferences-margin* *preferences-row*)))
    (objc:invoke window "setReleasedWhenClosed:" nil)
    (objc:invoke window "setTitle:" "Settings")
    (setf *preference-controls* '())
    (loop for (key title) in *preference-switches*
          do (let ((box (objc:invoke "NSButton" "checkboxWithTitle:target:action:"
                                     title target
                                     (objc:coerce-to-selector "preferenceToggled:"))))
               (objc:invoke box "setFrame:"
                            (vector *preferences-margin* y
                                    (- width (* 2 *preferences-margin*)) 22d0))
               (objc:invoke content "addSubview:" box)
               (push (cons key box) *preference-controls*)
               (decf y *preferences-row*)))
    (let ((label (objc:invoke "NSTextField" "labelWithString:" "Size of the type"))
          (popup (objc:invoke (objc:invoke "NSPopUpButton" "alloc")
                              "initWithFrame:pullsDown:"
                              (vector 150d0 (- y 2d0) 80d0 26d0) nil)))
      (objc:invoke label "setFrame:" (vector *preferences-margin* y 124d0 20d0))
      (dolist (size *preference-font-sizes*)
        (objc:invoke popup "addItemWithTitle:" (font-size-title size)))
      (objc:invoke popup "setTarget:" target)
      (objc:invoke popup "setAction:" (objc:coerce-to-selector "preferenceFontSize:"))
      (objc:invoke content "addSubview:" label)
      (objc:invoke content "addSubview:" popup)
      (push (cons :font-size popup) *preference-controls*)
      ;; -addSubview: retains it; the +1 from -alloc is ours to drop.
      (objc:release popup))
    (decf y *preferences-row*)
    ;; And everything Settings has no control for.
    (let ((button (objc:invoke "NSButton" "buttonWithTitle:target:action:"
                               "Edit init.lisp…" target
                               (objc:coerce-to-selector "preferenceEditInitFile:"))))
      (objc:invoke button "setFrame:" (vector (- *preferences-margin* 6d0) (- y 4d0) 150d0 28d0))
      (objc:invoke content "addSubview:" button)
      (push (cons :init-file button) *preference-controls*))
    (objc:invoke window "center")
    (setf *preferences-controller* controller
          *preferences-window* window)))

(defun sync-preferences-window ()
  "Make the controls say what is in force.  Nothing to do with no window."
  (when (live-pointer-p *preferences-window*)
    (loop for (key . control) in *preference-controls*
          unless (eq key :init-file)
          do (if (eq key :font-size)
                 (let ((title (font-size-title (preference :font-size))))
                   ;; A size init.lisp or ⌘+ chose need not be one on the list.
                   (when (minusp (objc:invoke control "indexOfItemWithTitle:" title))
                     (objc:invoke control "addItemWithTitle:" title))
                   (objc:invoke control "selectItemWithTitle:" title))
                 (objc:invoke control "setState:" (if (preference key) 1 0)))))
  t)

(defun show-preferences-window ()
  (unless (live-pointer-p *preferences-window*)
    (build-preferences-window))
  (sync-preferences-window)
  (objc:invoke *preferences-window* "makeKeyAndOrderFront:" nil)
  t)

(defun hide-preferences-window ()
  "Close Settings, if it is open: it goes with the last listener."
  (when (and (live-pointer-p *preferences-window*)
             (objc:invoke-bool *preferences-window* "isVisible"))
    (objc:invoke *preferences-window* "close"))
  t)

(defun preference-control (key)
  "The control for KEY, for the driver to press."
  (cdr (assoc key *preference-controls*)))
