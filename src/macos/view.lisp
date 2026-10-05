;;;; src/macos/view.lisp -- LispListenerView, over NSTextView.
;;;;
;;;; The transcript itself is src/transcript.lisp and is shared with iOS.  This
;;;; is what AppKit needs besides: the class, the colours and font, the run loop
;;;; modes a hop to thread 1 is queued in, and the methods NSTextView sends --
;;;; Return, the arrow keys, Tab, and the delegate's edit check.

(in-package #:lisp-listener)

;;; AppKit constants ----------------------------------------------------------

(defconstant +ns-view-width-and-height-sizable+ 18)
(defconstant +ns-window-style-titled+ 1)
(defconstant +ns-window-style-closable+ 2)
(defconstant +ns-window-style-mask+ 15
  "Titled, closable, miniaturizable, resizable.")
(defconstant +ns-backing-store-buffered+ 2)
(defconstant +png-file-type+ 4
  "NSBitmapImageFileTypePNG, for -representationUsingType:properties:.")

(defparameter +common-run-loop-modes+
  #("NSDefaultRunLoopMode" "NSEventTrackingRunLoopMode" "NSModalPanelRunLoopMode")
  "The run loop modes a queued selector is delivered in: the default one, and
the ones the main thread runs while a window is being resized or a panel is up,
so a request made then still arrives.

Named one by one rather than as the common-modes pseudo mode.  Measured in
lem-cocoa: a perform queued in the mode named kCFRunLoopCommonModes from a Lisp
thread never ran, and every perform queued after it stayed behind it.

A Lisp vector; INVOKE converts it to an NSArray of NSStrings on the way in.")

(defun main-thread-run-loop-modes () +common-run-loop-modes+)

(defun history-directory ()
  "~/Library/Application Support/Lisp Listener/, which is where a Mac
application keeps something it wrote for itself."
  (merge-pathnames "Library/Application Support/Lisp Listener/"
                   (user-homedir-pathname)))

(defun transcript-color (kind)
  (ecase kind
    ((:output :input) (objc:invoke "NSColor" "textColor"))
    (:prompt (objc:invoke "NSColor" "systemBlueColor"))
    (:value (objc:invoke "NSColor" "systemGreenColor"))
    (:error (objc:invoke "NSColor" "systemRedColor"))
    (:note (objc:invoke "NSColor" "secondaryLabelColor"))))


(defun paren-background-color (kind)
  "The tint behind a parenthesis: a quiet grey for a matched pair, red for one
with no partner.  System colours, so both follow the appearance."
  (ecase kind
    (:match (objc:invoke "NSColor" "unemphasizedSelectedTextBackgroundColor"))
    (:mismatch (objc:invoke (objc:invoke "NSColor" "systemRedColor")
                            "colorWithAlphaComponent:" 0.35d0))))

(defun invalidate-key-commands ()
  "Nothing to do on the Mac: -keyDown: reads *PAREDIT-KEYS* on every key."
  nil)

(defun transcript-font (size)
  (objc:invoke "NSFont" "monospacedSystemFontOfSize:weight:" size 0d0))

;;; The view ------------------------------------------------------------------

(objc:define-objc-class listener-text-view ()
  ((role :initform :listener :accessor view-role
         :documentation ":LISTENER, the prompt and its transcript; or :EDITOR,
a file being edited, whose input region is all of it.  See src/editor.lisp.")
   (editor :initform nil :accessor view-editor
           :documentation "An editor view's EDITOR.")
   (input-start :initform 0 :accessor view-input-start
                :documentation "Index in the text storage where editable text
begins.  UTF-16 units, thread 1 only.")
   (history :initform '() :accessor view-history
            :documentation "Submitted lines, newest first.")
   (history-index :initform nil :accessor view-history-index
                  :documentation "How far back RECALL-HISTORY has gone, or NIL
while a fresh line is being typed.")
   (paren-marks :initform '() :accessor view-paren-marks
                :documentation "The ranges the paren highlight last tinted, so
that they can be untinted.  Thread 1 only; see src/paren-highlight.lisp."))
  (:objc-class-name "LispListenerView")
  (:objc-superclass-name "NSTextView"))



;;; The Objective-C methods ---------------------------------------------------

(define-listener-method ("listenerDrainQueue" :void) ()
  (drain-main-thread-queue))

(defun dragged-file-paths (dragging-info)
  "The file paths on a drag's pasteboard, as Lisp strings; NIL when it carries
none.  Asked of NSURL, which is how a file arrives from the Finder."
  (let* ((pasteboard (objc:invoke dragging-info "draggingPasteboard"))
         (urls (objc:invoke pasteboard "readObjectsForClasses:options:"
                            (objc:invoke "NSArray" "arrayWithObject:"
                                         (objc:coerce-to-objc-class "NSURL"))
                            (cffi:null-pointer))))
    (unless (cffi:null-pointer-p urls)
      (loop for i from 0 below (objc:invoke urls "count")
            for url = (objc:invoke urls "objectAtIndex:" i)
            when (objc:invoke-bool url "isFileURL")
              collect (objc:ns-string-to-string (objc:invoke url "path"))))))

;;; A Lisp file dropped on the window is loaded into it, as File > Open... would.
;;; Anything else -- text, a file that is not Lisp -- is the text view's, which
;;; inserts it as it always has.
(define-listener-method ("performDragOperation:" objc:objc-bool)
    ((sender objc:objc-object-pointer))
  (let ((paths (remove-if-not #'loadable-file-p (dragged-file-paths sender))))
    (if paths
        (progn (load-files-into-listener *listener* paths) t)
        (objc:invoke-bool (objc:current-super) "performDragOperation:" sender))))

(define-listener-method ("insertNewline:" :void)
    ((sender objc:objc-object-pointer))
  (submit-input self pointer))

;;; Option-Return, and Ctrl-O: AppKit's standard key bindings send both here.
;;; The line is broken and indented, and nothing is submitted.
(define-listener-method ("insertNewlineIgnoringFieldEditor:" :void)
    ((sender objc:objc-object-pointer))
  (unless (insert-indented-newline self pointer)
    (objc:invoke (objc:current-super) "insertNewlineIgnoringFieldEditor:" sender)))

;;; The start of the line is after the prompt.  C-a is
;;; -moveToBeginningOfParagraph: in AppKit's standard bindings, Home and ⌘← are
;;; the other two, and each has a twin that extends the selection (with Shift).
;;; Only the input's first line is ours: on any other, and up in the
;;; transcript, the left margin is the start of the line and super has it.
(macrolet ((define-line-start (selector extend)
             `(define-listener-method (,selector :void)
                  ((sender objc:objc-object-pointer))
                (unless (and (caret-on-first-input-line-p self pointer)
                             (move-to-input-line-start self pointer :extend ,extend))
                  (objc:invoke (objc:current-super) ,selector sender)))))
  (define-line-start "moveToBeginningOfParagraph:" nil)
  (define-line-start "moveToBeginningOfLine:" nil)
  (define-line-start "moveToLeftEndOfLine:" nil)
  (define-line-start "moveToBeginningOfParagraphAndModifySelection:" t)
  (define-line-start "moveToBeginningOfLineAndModifySelection:" t)
  (define-line-start "moveToLeftEndOfLineAndModifySelection:" t))

(defun add-value-link (storage range link)
  "Make RANGE of the transcript a link whose text is LINK.  AppKit tells the
view of a click on one: -textView:clickedOnLink:atIndex:."
  (objc:invoke storage "addAttribute:value:range:"
               (%ns-string-constant "NSLinkAttributeName") link range))

;;; A value printed at the prompt is a link to itself (TRANSCRIPT-INSERT), and
;;; a click on one opens the inspector on it.  Answering true says the click
;;; has been dealt with; a link that is not ours is left to AppKit.
(define-listener-method ("textView:clickedOnLink:atIndex:" objc:objc-bool)
    ((text-view objc:objc-object-pointer)
     (link objc:objc-object-pointer)
     (index (:unsigned :long-long)))
  (inspect-shown-value *listener*
                       (objc:ns-string-to-string (objc:invoke link "description"))))

(define-listener-method ("moveUp:" :void)
    ((sender objc:objc-object-pointer))
  (unless (and (caret-on-first-input-line-p self pointer)
               (recall-history self pointer -1))
    (objc:invoke (objc:current-super) "moveUp:" sender)))

(define-listener-method ("moveDown:" :void)
    ((sender objc:objc-object-pointer))
  (unless (and (caret-on-last-input-line-p self pointer)
               (recall-history self pointer 1))
    (objc:invoke (objc:current-super) "moveDown:" sender)))

;;; The view is its own delegate.  AppKit dispatches a delegate method through
;;; -respondsToSelector:, which a real class_addMethod'd IMP satisfies, so
;;; there is nothing to declare and no second object to keep alive.
;;;
;;; On an error the edit is ALLOWED.  Refusing by default would make a bug in
;;; here look like a text view that has stopped accepting typing.

(define-listener-method ("textView:shouldChangeTextInRange:replacementString:"
                         objc:objc-bool :on-error t)
    ((text-view objc:objc-object-pointer)
     (affected cocoa:ns-range)
     (replacement objc:objc-object-pointer))
  (input-edit-allowed-p self affected))

(define-listener-method ("acceptsFirstResponder" objc:objc-bool :on-error t) ()
  t)

(define-listener-method ("textViewDidChangeSelection:" :void)
    ((notification objc:objc-object-pointer))
  ;; The typing attributes first: AppKit takes them from the character at the
  ;; insertion point, which may be a tinted paren, and then the next character
  ;; typed arrives wearing the tint.  UIKit resets them on its own account and
  ;; src/ios/view.lisp does the same thing for the same reason.
  (apply-typing-attributes pointer)
  (refresh-paren-highlight self pointer)
  (refresh-arglist-hint self pointer))

;;; Paredit ---------------------------------------------------------------------
;;;
;;; Three hooks, and the division between them is AppKit's, not ours:
;;;
;;;   -insertText:replacementRange: is where a SELF-INSERTING character arrives,
;;;   and the only hook that can see which character it is.  ( ) and " are
;;;   handled here.
;;;
;;;   -deleteBackward: is Backspace, which has a standard selector of its own.
;;;
;;;   -keyDown: is for the CHORDS -- C-) M-( C-M-f -- which AppKit's key
;;;   bindings map to nothing at all, so no standard selector is ever sent.  It
;;;   calls super for everything it does not claim, which is what keeps Return,
;;;   Tab, the arrows and Escape arriving at the IMPs above: they come through
;;;   -interpretKeyEvents:, which is what super does.  Overriding -keyDown: to
;;;   do more than this would put us in front of dead keys and input methods.
;;;
;;; Each falls through to super when paredit is off, when the caret is above the
;;; prompt, or when the command declines -- so a key never does nothing.

(define-listener-method ("insertText:replacementRange:" :void)
    ((text objc:objc-object-pointer)
     (range cocoa:ns-range))
  (let ((string (ignore-errors (objc:ns-string-to-string text))))
    (unless (and string
                 (= 1 (length string))
                 (paredit-handles-character-p self pointer (char string 0)))
      (objc:invoke (objc:current-super) "insertText:replacementRange:" text range))))

(define-listener-method ("deleteBackward:" :void)
    ((sender objc:objc-object-pointer))
  (unless (paredit-handles-character-p self pointer #\Backspace)
    (objc:invoke (objc:current-super) "deleteBackward:" sender)))

(define-listener-method ("deleteForward:" :void)
    ((sender objc:objc-object-pointer))
  (unless (paredit-handles-character-p self pointer #\Rubout)
    (objc:invoke (objc:current-super) "deleteForward:" sender)))

(defconstant +ns-event-modifier-control+ (ash 1 18))
(defconstant +ns-event-modifier-option+ (ash 1 19))

(defun event-modifiers (event)
  "The subset of an NSEvent's modifiers paredit binds: Control, and Option as
Meta -- which is what a Mac keyboard offers for M-."
  (let ((flags (objc:invoke event "modifierFlags"))
        (modifiers '()))
    (when (plusp (logand flags +ns-event-modifier-control+))
      (push :control modifiers))
    (when (plusp (logand flags +ns-event-modifier-option+))
      (push :meta modifiers))
    modifiers))

(define-listener-method ("keyDown:" :void)
    ((event objc:objc-object-pointer))
  (let* ((modifiers (event-modifiers event))
         (characters (and modifiers
                          (ignore-errors
                           (objc:ns-string-to-string
                            (objc:invoke event "charactersIgnoringModifiers"))))))
    (unless (and characters
                 (= 1 (length characters))
                 (paredit-handles-character-p self pointer (char characters 0) modifiers))
      (objc:invoke (objc:current-super) "keyDown:" event))))

;;; Completion ------------------------------------------------------------------
;;;
;;; NSTextView already has completion: -complete: asks the view for the range
;;; being completed (-rangeForUserCompletion) and for the candidates
;;; (-completionsForPartialWordRange:indexOfSelectedItem:), then shows its own
;;; popup.  These answer with src/completion.lisp's symbol tokens and symbols.
;;;
;;; Tab goes to SUPER's -complete:, never to the view's own.  That override,
;;; in restarts-panel.lisp, is Escape's, and it first cancels any debugger level --
;;; which Tab must not do.  Escape still completes, through its fall-through.
;;;
;;; One candidate is inserted straight away rather than offered in a popup of
;;; one.  None, or several, go to -complete:, which beeps for none.

(define-listener-method ("insertTab:" :void)
    ((sender objc:objc-object-pointer))
  (multiple-value-bind (token range) (completion-token self pointer)
    (let ((candidates (and token (listener-completions token))))
      (cond ((null token)
             (objc:invoke (objc:current-super) "insertTab:" sender))
            ((and candidates (null (rest candidates)))
             (replace-token self pointer range (first candidates)))
            (t
             (objc:invoke (objc:current-super) "complete:" sender))))))

(define-listener-method ("rangeForUserCompletion" cocoa:ns-range) ()
  (multiple-value-bind (token range) (completion-token self pointer)
    (if token
        range
        (objc:invoke (objc:current-super) "rangeForUserCompletion"))))

;;; The array is autoreleased: an object a Lisp method returns is the caller's
;;; to release, and AppKit does not expect to own this one.  *INDEX is left at
;;; AppKit's own default, which selects the first candidate.

(define-listener-method ("completionsForPartialWordRange:indexOfSelectedItem:"
                         objc:objc-object-pointer)
    ((range cocoa:ns-range)
     (index :pointer))
  (let ((token (transcript-substring pointer (car range) (cdr range)))
        (array (objc:invoke "NSMutableArray" "array")))
    (dolist (candidate (listener-completions token) array)
      (objc:invoke array "addObject:" candidate))))

;;; What the call being typed takes, in the window's subtitle: under the title,
;;; out of the way of the transcript, and gone when there is nothing to say.
;;; A subtitle is plain text, so the argument at the caret is bracketed.

(defun show-arglist-hint (listener hint start end &optional view)
  (let ((window (if view
                    (objc:invoke (objc:objc-object-pointer view) "window")
                    (listener-window listener))))
    (when (live-pointer-p window)
      (objc:invoke window "setSubtitle:"
                   (cond ((null hint) "")
                         ((and start end)
                          (concatenate 'string (subseq hint 0 start)
                                       "‹" (subseq hint start end) "›"
                                       (subseq hint end)))
                         (t hint))))
    t))
