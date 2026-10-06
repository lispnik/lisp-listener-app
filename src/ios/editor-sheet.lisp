;;;; src/ios/editor-sheet.lisp -- the editor, as a sheet.
;;;;
;;;; iOS's half of src/editor.lisp: one file at a time, in a LispListenerView
;;;; whose role is :EDITOR, in a sheet at full height.  Across the top, Close,
;;;; the file's name -- with a dot while it says other than the file -- Open...
;;;; and Save; over the keyboard, the editor's own keys (src/ios/view.lisp):
;;;; Tab, the four arrows, Eval, Load, Save and Close.  Under the header, what
;;;; the last form evaluated said, once the listener has said it -- the
;;;; transcript is behind the sheet.
;;;;
;;;; The file is saved when the editor closes or opens another, as a phone's
;;;; editors do; Save is there for the moment you want it now.  Edit on the
;;;; listener's key bar opens it on the file last edited, or on scratch.lisp in
;;;; the app's folder; Settings > Edit opens it on init.lisp.
;;;;
;;;; One editor, made once and kept, like the canvas.  Thread 1, all of it.

(in-package #:lisp-listener)

;;; Defined in app.lisp, which loads after this file.
(declaim (ftype function lisp-content-types))

(defparameter *editor-scratch-name* "scratch.lisp")

(defvar *editor* nil
  "The one editor: an EDITOR, made the first time it is asked for.")

(defvar *editor-controller* nil
  "Its sheet's UIViewController, retained for the life of the app.")

(defvar *editor-parts* '()
  "The sheet's labels, as a plist: :title and :result.")

(defvar *editor-sheet-delegate* nil
  "The sheet's delegate, held: a presentation controller holds it weakly.")

(objc:define-objc-class editor-sheet-delegate ()
  ()
  (:objc-class-name "LispListenerEditorSheetDelegate"))

;;; Dragged down by the person, rather than closed with a key: save, as Close
;;; does.  UIKit sends this only for a dismissal it did itself.
(objc:define-objc-method ("presentationControllerDidDismiss:" :void)
    ((self editor-sheet-delegate) (presentation objc:objc-object-pointer))
  (declare (ignorable presentation))
  (handler-case (editor-sheet-save-if-changed *editor*)
    (error (condition) (note "editor presentationControllerDidDismiss: ~a" condition))))

;;; The file ------------------------------------------------------------------------

(defun editor-default-path ()
  "The file Edit opens: the one last edited, while it is still there, and
scratch.lisp in the app's folder otherwise."
  (let ((last (remembered :editor-file)))
    (or (and last (probe-file last))
        (merge-pathnames *editor-scratch-name* (history-directory)))))

(defun editor-sheet-save (editor)
  "Save, and say so in the title."
  (when (and editor (editor-path editor))
    (editor-save editor)
    (note-editor-changed editor)
    t))

(defun editor-sheet-save-if-changed (editor)
  (when (and editor (editor-path editor) (editor-dirty-p editor))
    (editor-sheet-save editor)))

(defun note-editor-changed (editor)
  "Put the file's name in the title, with a dot while the buffer and the file
disagree."
  (let ((title (getf *editor-parts* :title)))
    (when (and editor (live-pointer-p title))
      (objc:invoke title "setText:"
                   (format nil "~a~:[~; •~]"
                           (if (editor-path editor)
                               (file-namestring (editor-path editor))
                               "untitled")
                           (editor-dirty-p editor))))))

;;; What a form said --------------------------------------------------------------
;;;
;;; The value comes to the transcript, behind the sheet, a moment after the form
;;; is typed there.  So the transcript's length is noted, and when the listener
;;; is back at a prompt what was written after that point -- less the echo of
;;; the form and the new prompt -- is shown under the header.

(defparameter *editor-result-limit* 400)

(defun editor-result-text (written)
  "What WRITTEN, the transcript after the form, says: its last lines, less the
prompt that ends it."
  (let* ((lines (remove "" (split-lines written) :test #'string=))
         ;; The first is the form, echoed as it was typed; the last is the
         ;; prompt now waiting.
         (form (first lines))
         (said (butlast (rest lines))))
    (clip-string (if said
                     (format nil "~a  ⇒  ~{~a~^  ~}" form (last said 3))
                     (or form ""))
                 *editor-result-limit*)))

(defun split-lines (string)
  (loop with start = 0
        for newline = (position #\Newline string :start start)
        collect (subseq string start newline)
        while newline
        do (setf start (1+ newline))))

(defun watch-for-result (editor before)
  "Show what the listener says after the transcript's first BEFORE units, once
it is waiting at a prompt again; give up after ten seconds."
  (let ((listener (editor-listener editor))
        (label (getf *editor-parts* :result))
        (started (get-internal-real-time)))
    (objc:invoke label "setText:" "…")
    (objc:invoke label "setTextColor:" (objc:invoke "UIColor" "secondaryLabelColor"))
    (uikit:after-every
     0.1d0
     (lambda (timer)
       (let ((pointer (listener-view listener))
             (seconds (/ (- (get-internal-real-time) started)
                         internal-time-units-per-second)))
         (cond ((> seconds 10)
                (objc:invoke label "setText:" "still running; the transcript will have it")
                (objc:invoke timer "invalidate"))
               ;; A prompt AFTER what was typed.  The form typed at the prompt
               ;; is in the transcript at once, and until the listener thread
               ;; reads it the old prompt is still the recorded one: asking
               ;; only for a prompt and a longer transcript, a busy iPad showed
               ;; the form itself as its result, and never looked again.
               ((let ((prompt (listener-prompt listener)))
                  (and prompt
                       (> (transcript-length pointer) before)
                       (string= prompt (last-line-of (transcript-substring
                                                      pointer before
                                                      (- (transcript-length pointer) before))))))
                (let* ((written (transcript-substring pointer before
                                                      (- (transcript-length pointer) before)))
                       (debugger (search "[1]" (last-line-of written))))
                  (objc:invoke label "setText:" (editor-result-text written))
                  (objc:invoke label "setTextColor:"
                               (objc:invoke "UIColor"
                                            (if debugger "systemRedColor" "systemGreenColor"))))
                (objc:invoke timer "invalidate"))))))))

(defun last-line-of (text)
  (subseq text (1+ (or (position #\Newline text :from-end t) -1))))

(defun editor-sheet-evaluate (editor)
  "Evaluate the form at the caret at the prompt, and show what it said."
  (when editor
    (let* ((listener (editor-listener editor))
           (before (and listener (transcript-length (listener-view listener)))))
      (when (and before (editor-evaluate-form editor))
        (watch-for-result editor before)
        t))))

(defun editor-sheet-load (editor)
  "Save, and load the file at the prompt, and show what that said."
  (when (and editor (editor-path editor))
    (let* ((listener (editor-listener editor))
           (before (and listener (transcript-length (listener-view listener)))))
      (editor-load editor)
      (note-editor-changed editor)
      (when before (watch-for-result editor before))
      t)))

;;; Opening another file -------------------------------------------------------------

(objc:define-objc-class editor-picker-delegate ()
  ()
  (:objc-class-name "LispListenerEditorPickerDelegate"))

(defvar *editor-picker-delegate* nil)

(objc:define-objc-method ("documentPicker:didPickDocumentsAtURLs:" :void)
    ((self editor-picker-delegate)
     (picker objc:objc-object-pointer)
     (urls objc:objc-object-pointer))
  (declare (ignorable picker))
  (handler-case
      (when (plusp (objc:invoke urls "count"))
        (let* ((url (objc:invoke urls "objectAtIndex:" 0))
               (path (objc:ns-string-to-string (objc:invoke url "path")))
               (scoped (objc:invoke-bool url "startAccessingSecurityScopedResource")))
          ;; One from outside the app's folder is copied in, as Open does, and
          ;; it is the copy that is edited: it can be read only for now.
          (let ((local (unwind-protect (import-opened-file path (history-directory))
                         (when scoped (objc:invoke url "stopAccessingSecurityScopedResource")))))
            (editor-switch-to *editor* local))))
    (error (condition) (note "editor documentPicker: ~a" condition))))

(defun show-editor-picker ()
  (unless *editor-picker-delegate*
    (setf *editor-picker-delegate* (uikit:keep (make-instance 'editor-picker-delegate))))
  (let ((picker (objc:invoke (objc:invoke "UIDocumentPickerViewController" "alloc")
                             "initForOpeningContentTypes:asCopy:" (lisp-content-types) nil)))
    (objc:invoke picker "setDelegate:" (objc:objc-object-pointer *editor-picker-delegate*))
    (objc:invoke *editor-controller* "presentViewController:animated:completion:"
                 picker t nil)
    (objc:release picker)
    t))

(defun editor-switch-to (editor path)
  "Save what is being edited, and edit PATH instead."
  (editor-sheet-save-if-changed editor)
  (editor-open editor path)
  (setf (getf *remembered* :editor-file) (namestring (editor-path editor)))
  (save-preferences)
  (note-editor-changed editor)
  (objc:invoke (getf *editor-parts* :result) "setText:" "")
  editor)

;;; The sheet -----------------------------------------------------------------------

(defun build-editor-sheet (listener)
  "The editor, its view and its sheet's controller.  Made once."
  (let* ((editor (%make-editor :listener listener))
         (controller (objc:invoke (objc:invoke "UIViewController" "alloc") "init"))
         (root (objc:invoke controller "view"))
         (header (uikit:new "UIStackView"))
         (close (uikit:system-button "Close"))
         (title (uikit:new "UILabel"))
         (open (uikit:system-button "Open…"))
         (save (uikit:system-button "Save"))
         (result (uikit:new "UILabel")))
    (multiple-value-bind (pointer object) (make-listener-view :role :editor :editor editor)
      (setf (editor-view editor) object
            (editor-pointer editor) pointer)
      (objc:invoke root "setBackgroundColor:" (objc:invoke "UIColor" "systemBackgroundColor"))
      (objc:invoke header "setAxis:" 0)
      (objc:invoke header "setSpacing:" 14d0)
      (objc:invoke header "setAlignment:" 3)
      (objc:invoke title "setFont:" (uikit:bold-font 17))
      (objc:invoke title "setLineBreakMode:" 5)   ; truncating middle
      (objc:invoke title "setContentHuggingPriority:forAxis:" 1.0 0)
      (objc:invoke title "setContentCompressionResistancePriority:forAxis:" 1.0 0)
      (uikit:on-tap close (lambda (sender) (declare (ignore sender)) (hide-editor-sheet)))
      (uikit:on-tap open (lambda (sender) (declare (ignore sender)) (show-editor-picker)))
      (uikit:on-tap save (lambda (sender) (declare (ignore sender)) (editor-sheet-save editor)))
      (dolist (view (list close title open save))
        (objc:invoke header "addArrangedSubview:" view))
      (objc:invoke result "setFont:" (uikit:mono-font 13))
      (objc:invoke result "setLineBreakMode:" 4)   ; truncating tail
      (objc:invoke root "addSubview:" header)
      (objc:invoke root "addSubview:" result)
      (objc:invoke root "addSubview:" pointer)
      (let ((safe (objc:invoke root "safeAreaLayoutGuide")))
        (uikit:pin header "topAnchor" root "topAnchor" 18)
        (uikit:pin header "leadingAnchor" safe "leadingAnchor" 16)
        (uikit:pin header "trailingAnchor" safe "trailingAnchor" -16)
        (uikit:pin result "topAnchor" header "bottomAnchor" 6)
        (uikit:pin result "leadingAnchor" safe "leadingAnchor" 16)
        (uikit:pin result "trailingAnchor" safe "trailingAnchor" -16)
        (uikit:pin pointer "topAnchor" result "bottomAnchor" 6)
        (uikit:pin pointer "leadingAnchor" safe "leadingAnchor" 6)
        (uikit:pin pointer "trailingAnchor" safe "trailingAnchor" -6)
        (uikit:pin pointer "bottomAnchor" (objc:invoke root "keyboardLayoutGuide") "topAnchor"))
      (let ((sheet (objc:invoke controller "sheetPresentationController")))
        (when (live-pointer-p sheet)
          (let ((detents (objc:invoke "NSMutableArray" "array")))
            (objc:invoke detents "addObject:"
                         (objc:invoke "UISheetPresentationControllerDetent" "largeDetent"))
            (objc:invoke sheet "setDetents:" detents)
            (objc:invoke sheet "setPrefersGrabberVisible:" t)
            (unless *editor-sheet-delegate*
              (setf *editor-sheet-delegate* (make-instance 'editor-sheet-delegate)))
            (objc:invoke sheet "setDelegate:"
                         (objc:objc-object-pointer *editor-sheet-delegate*)))))
      (setf *editor* editor
            *editor-controller* controller
            *editor-parts* (list :title title :result result))
      editor)))

(defun editor-sheet-up-p ()
  (and (live-pointer-p *editor-controller*)
       (live-pointer-p (objc:invoke *editor-controller* "presentingViewController"))))

(defun show-editor-sheet (&optional path (listener (current-listener)))
  "Put the editor up on PATH -- or, with none, on what it last had, or the file
last edited, or scratch.lisp."
  (when listener
    (unless *editor* (build-editor-sheet listener))
    (setf (editor-listener *editor*) listener)
    (let ((wanted (or path (editor-path *editor*) (editor-default-path))))
      (unless (and (editor-path *editor*)
                   (equal (namestring (editor-path *editor*)) (namestring wanted)))
        (editor-switch-to *editor* wanted)))
    (note-editor-changed *editor*)
    (unless (editor-sheet-up-p)
      (present-sheet listener *editor-controller*))
    ;; The keyboard, once the sheet is there to have it.
    (objc:invoke (editor-pointer *editor*) "performSelector:withObject:afterDelay:"
                 (objc:coerce-to-selector "becomeFirstResponder") nil 0.4d0)
    *editor*))

(defun hide-editor-sheet ()
  "Save, and put the editor away.  Idempotent."
  (when *editor*
    (editor-sheet-save-if-changed *editor*)
    (let ((listener (editor-listener *editor*)))
      (when (and listener (live-pointer-p *editor-controller*))
        (dismiss-sheet-when-settled (listener-view listener) *editor-controller*))))
  t)
