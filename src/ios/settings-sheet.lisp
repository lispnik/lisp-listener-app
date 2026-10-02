;;;; src/ios/settings-sheet.lisp -- Settings: four switches and a size.
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
    (when (settings-sheet-up-p)
      (objc:invoke *settings-controller* "dismissViewControllerAnimated:completion:" t nil))
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
    (objc:invoke (presenting-controller listener)
                 "presentViewController:animated:completion:"
                 *settings-controller* t nil)
    t))
