;;;; src/ios/settings-sheet.lisp -- Settings: five switches, a size, and
;;;; init.lisp.
;;;;
;;;; iOS's window onto src/preferences.lisp, as src/macos/preferences-window.lisp
;;;; is the Mac's: a sheet with a UISwitch for each switch and a UIStepper for
;;;; the size of the type.  Each control changes its setting at once, through
;;;; (SETF PREFERENCE), which is also what saves it; Done only puts the sheet
;;;; away.  The ⚙ key on the bar above the keyboard opens it, and ⌘, on a
;;;; keyboard.
;;;;
;;;; "Reopen windows" is not here: there is one window and iOS decides when it
;;;; opens.
;;;;
;;;; Thread 1, all of it.

(in-package #:lisp-listener)

(defparameter *settings-switches*
  '((:paredit "Balance parentheses and quotes")
    (:paren-highlight "Tint the matching parenthesis")
    (:arglist-hints "Show what a call takes")
    (:auto-indent "Indent a new line")
    (:debugger-pane "Show restarts in a sheet"))
  "The switches, top to bottom: the preference and what it says.")

(defconstant +ui-control-event-value-changed+ 4096)

(defvar *settings-controller* nil
  "The sheet's UIViewController while one is up, retained; NIL otherwise.")

(defvar *settings-controls* '()
  "The controls of the sheet that is up, as (KEY . POINTER): a UISwitch for
each switch, the UIStepper under :FONT-SIZE and its label under :FONT-SIZE-LABEL.")

(defun settings-control (key)
  "The control for KEY, for the self-test to work."
  (cdr (assoc key *settings-controls*)))

(defun font-size-label-text ()
  (format nil "Size of the type: ~d" (round (preference :font-size))))

(defun on-value-changed (control function)
  "Call FUNCTION with CONTROL when its value changes.  UIKIT:ON-TAP is for a
button; a switch and a stepper report a new value, not a touch."
  (objc:invoke control "addTarget:action:forControlEvents:"
               (uikit:action-target function) "fire:"
               +ui-control-event-value-changed+)
  control)

(defun settings-row (title control)
  "A row: TITLE on the left, CONTROL on the right.  Answers the row and its label."
  (let ((row (uikit:new "UIStackView"))
        (label (uikit:new "UILabel")))
    (objc:invoke row "setAxis:" 0)              ; horizontal
    (objc:invoke row "setAlignment:" 3)         ; UIStackViewAlignmentCenter
    (objc:invoke row "setSpacing:" 12d0)
    (objc:invoke label "setText:" title)
    (objc:invoke label "setFont:" (uikit:font 16))
    (objc:invoke label "setNumberOfLines:" 0)
    ;; The label is the one that stretches (hugging priority 1, horizontally):
    ;; left to itself a wide row stretched the button, and Done sat in the
    ;; middle of an iPad's sheet.
    (objc:invoke label "setContentHuggingPriority:forAxis:" 1.0 0)
    (objc:invoke row "addArrangedSubview:" label)
    (objc:invoke row "addArrangedSubview:" control)
    (values row label)))

(defun build-settings-sheet ()
  "The sheet's controller, its controls saying what is in force.  +1."
  (let* ((controller (objc:invoke (objc:invoke "UIViewController" "alloc") "init"))
         (root (objc:invoke controller "view"))
         (stack (uikit:new "UIStackView"))
         (done (uikit:system-button "Done")))
    (setf *settings-controls* '())
    (objc:invoke root "setBackgroundColor:"
                 (objc:invoke "UIColor" "systemBackgroundColor"))
    (objc:invoke stack "setAxis:" 1)            ; vertical
    (objc:invoke stack "setSpacing:" 18d0)
    (uikit:on-tap done (lambda (sender)
                         (declare (ignore sender))
                         (hide-settings-sheet)))
    ;; The title shares the first row with Done.
    (multiple-value-bind (row label) (settings-row "Settings" done)
      (objc:invoke label "setFont:" (uikit:bold-font 20))
      (objc:invoke stack "addArrangedSubview:" row))
    (loop for (key text) in *settings-switches*
          do (let ((switch (uikit:new "UISwitch"))
                   (key key))
               (objc:invoke switch "setOn:" (and (preference key) t))
               (on-value-changed switch
                                 (lambda (sender)
                                   (setf (preference key)
                                         (objc:invoke-bool sender "isOn"))
                                   (preferences-changed)))
               (objc:invoke stack "addArrangedSubview:" (settings-row text switch))
               (push (cons key switch) *settings-controls*)))
    (let ((stepper (uikit:new "UIStepper")))
      (objc:invoke stepper "setMinimumValue:" (float (car *font-size-range*) 1d0))
      (objc:invoke stepper "setMaximumValue:" (float (cdr *font-size-range*) 1d0))
      (objc:invoke stepper "setStepValue:" 1d0)
      (objc:invoke stepper "setValue:" (float (preference :font-size) 1d0))
      (multiple-value-bind (row label) (settings-row (font-size-label-text) stepper)
        (on-value-changed stepper
                          (lambda (sender)
                            (setf (preference :font-size) (objc:invoke sender "value"))
                            (objc:invoke label "setText:" (font-size-label-text))))
        (objc:invoke stack "addArrangedSubview:" row)
        (push (cons :font-size stepper) *settings-controls*)
        (push (cons :font-size-label label) *settings-controls*)))
    ;; Everything Settings has no switch for: init.lisp, edited here, since
    ;; nothing on a phone edits a .lisp file.
    (let ((edit (uikit:system-button "Edit")))
      (uikit:on-tap edit (lambda (sender)
                           (declare (ignore sender))
                           (show-init-file-editor)))
      (objc:invoke stack "addArrangedSubview:"
                   (settings-row "init.lisp, loaded at every launch" edit))
      (push (cons :init-file edit) *settings-controls*))
    (objc:invoke root "addSubview:" stack)
    (let ((safe (objc:invoke root "safeAreaLayoutGuide")))
      (uikit:pin stack "topAnchor" root "topAnchor" 24)
      (uikit:pin stack "leadingAnchor" safe "leadingAnchor" 20)
      (uikit:pin stack "trailingAnchor" safe "trailingAnchor" -20))
    (let ((sheet (objc:invoke controller "sheetPresentationController")))
      (when (live-pointer-p sheet)
        (let ((detents (objc:invoke "NSMutableArray" "array")))
          (objc:invoke detents "addObject:"
                       (objc:invoke "UISheetPresentationControllerDetent" "mediumDetent"))
          (objc:invoke detents "addObject:"
                       (objc:invoke "UISheetPresentationControllerDetent" "largeDetent"))
          (objc:invoke sheet "setDetents:" detents)
          (objc:invoke sheet "setPrefersGrabberVisible:" t))))
    controller))

(defun settings-sheet-up-p ()
  (and (live-pointer-p *settings-controller*)
       (live-pointer-p (objc:invoke *settings-controller* "presentingViewController"))))

(defun hide-settings-sheet ()
  "Dismiss the sheet and forget it.  Idempotent."
  (when (live-pointer-p *settings-controller*)
    (let ((listener (current-listener)))
      (when listener
        (dismiss-sheet-when-settled (listener-view listener) *settings-controller*)))
    (objc:release *settings-controller*))
  (setf *settings-controller* nil
        *settings-controls* '())
  t)

(defun show-settings-sheet (&optional (listener (current-listener)))
  "Present Settings.  Built afresh each time, so that it says what is in force
now, whoever set it -- init.lisp, ⌘+, or the prompt."
  (when listener
    (hide-settings-sheet)
    (setf *settings-controller* (build-settings-sheet))
    (present-sheet listener *settings-controller*)
    t))

;;; init.lisp, edited ----------------------------------------------------------------
;;;
;;; A sheet over Settings: the file in a text view, and Cancel, Save, and Save
;;; and Load -- which types (load ".../init.lisp") at the prompt, so that what
;;; was written is in force now and not only from the next launch, and any
;;; error in it opens the debugger like any other.

(defvar *init-editor* nil
  "The editor's controller while it is up, retained; NIL otherwise.")

(defvar *init-editor-text* nil
  "Its text view, for Save and for the self-test.")

(defun init-editor-up-p ()
  (and (live-pointer-p *init-editor*)
       (live-pointer-p (objc:invoke *init-editor* "presentingViewController"))))

(defun hide-init-file-editor ()
  "Put the editor away, saving nothing.  Idempotent."
  (when (live-pointer-p *init-editor*)
    (let ((listener (current-listener)))
      (when listener
        (dismiss-sheet-when-settled (listener-view listener) *init-editor*)))
    (objc:release *init-editor*))
  (setf *init-editor* nil
        *init-editor-text* nil)
  t)

(defun save-init-file-from-editor (&key load)
  "Write the editor's text to init.lisp, put the editor and Settings away, and
with LOAD, load it at the prompt.  Answers the pathname."
  (let ((path (init-file))
        (text (objc:ns-string-to-string (objc:invoke *init-editor-text* "text")))
        (listener (current-listener)))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :external-format :utf-8)
      (write-string text out))
    (hide-init-file-editor)
    (hide-settings-sheet)
    (when (and load listener)
      (load-files-into-listener listener (list path)))
    path))

(defun build-init-file-editor ()
  "The editor's controller, holding the file's text.  +1."
  (let* ((controller (objc:invoke (objc:invoke "UIViewController" "alloc") "init"))
         (root (objc:invoke controller "view"))
         (header (uikit:new "UIStackView"))
         (title (uikit:new "UILabel"))
         (cancel (uikit:system-button "Cancel"))
         (save (uikit:system-button "Save"))
         (load (uikit:system-button "Save and Load"))
         (text (uikit:new "UITextView"))
         (path (init-file)))
    (objc:invoke root "setBackgroundColor:" (objc:invoke "UIColor" "systemBackgroundColor"))
    (objc:invoke header "setAxis:" 0)
    (objc:invoke header "setSpacing:" 14d0)
    (objc:invoke header "setAlignment:" 3)
    (objc:invoke title "setText:" "init.lisp")
    (objc:invoke title "setFont:" (uikit:bold-font 17))
    (objc:invoke title "setContentHuggingPriority:forAxis:" 1.0 0)
    (uikit:on-tap cancel (lambda (sender) (declare (ignore sender)) (hide-init-file-editor)))
    (uikit:on-tap save (lambda (sender) (declare (ignore sender))
                         (save-init-file-from-editor)))
    (uikit:on-tap load (lambda (sender) (declare (ignore sender))
                         (save-init-file-from-editor :load t)))
    (dolist (view (list cancel title save load))
      (objc:invoke header "addArrangedSubview:" view))
    ;; Lisp, not prose: none of the keyboard's help.
    (objc:invoke text "setFont:" (transcript-font (float *font-size* 1d0)))
    (objc:invoke text "setAutocorrectionType:" +ui-text-autocorrection-no+)
    (objc:invoke text "setAutocapitalizationType:" +ui-text-autocapitalization-none+)
    (objc:invoke text "setSmartQuotesType:" +ui-text-smart-no+)
    (objc:invoke text "setSmartDashesType:" +ui-text-smart-no+)
    (objc:invoke text "setSpellCheckingType:" +ui-text-spell-checking-no+)
    (objc:invoke text "setText:"
                 (with-open-file (in path :external-format :utf-8)
                   (let ((string (make-string (file-length in))))
                     (subseq string 0 (read-sequence string in)))))
    (objc:invoke root "addSubview:" header)
    (objc:invoke root "addSubview:" text)
    (let ((safe (objc:invoke root "safeAreaLayoutGuide")))
      (uikit:pin header "topAnchor" root "topAnchor" 18)
      (uikit:pin header "leadingAnchor" safe "leadingAnchor" 16)
      (uikit:pin header "trailingAnchor" safe "trailingAnchor" -16)
      (uikit:pin text "topAnchor" header "bottomAnchor" 10)
      (uikit:pin text "leadingAnchor" safe "leadingAnchor" 12)
      (uikit:pin text "trailingAnchor" safe "trailingAnchor" -12)
      ;; Above the keyboard, which is up for as long as this is.
      (uikit:pin text "bottomAnchor" (objc:invoke root "keyboardLayoutGuide") "topAnchor" -8))
    (let ((sheet (objc:invoke controller "sheetPresentationController")))
      (when (live-pointer-p sheet)
        (let ((detents (objc:invoke "NSMutableArray" "array")))
          (objc:invoke detents "addObject:"
                       (objc:invoke "UISheetPresentationControllerDetent" "largeDetent"))
          (objc:invoke sheet "setDetents:" detents)
          (objc:invoke sheet "setPrefersGrabberVisible:" t))))
    (setf *init-editor-text* text)
    controller))

(defun show-init-file-editor (&optional (listener (current-listener)))
  "Present init.lisp to edit, made first if there is none.  Over Settings, if
that is up: PRESENT-SHEET presents from the top."
  (when listener
    (hide-init-file-editor)
    (setf *init-editor* (build-init-file-editor))
    (present-sheet listener *init-editor*)
    t))
