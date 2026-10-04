;;;; src/paren-highlight.lisp -- the parenthesis under the caret, and its partner.
;;;;
;;;; When the caret rests just after a `)' or just before a `(', both it and its
;;;; partner are given a background tint.  A paren with no partner is tinted as
;;;; a mismatch instead, which is how a missing one gets noticed while it is
;;;; still one keystroke from being fixed.
;;;;
;;;; ONLY INSIDE THE INPUT REGION.  The transcript above the prompt is other
;;;; people's parens -- output, prompts, printed values -- and matching across
;;;; that boundary would both mislead and mark text that is not being edited.
;;;; So the scan runs over PENDING-INPUT and every offset is relative to
;;;; INPUT-START.
;;;;
;;;; Recomputed from scratch, never incrementally.  That is deliberate:
;;;; REPLACE-PENDING-INPUT and REPLACE-TOKEN both reset the attributes over
;;;; their whole range with -setAttributes:range:, and output arriving from the
;;;; listener thread shifts every index, so any attempt to keep a highlight
;;;; alive across an edit would be wrong about half the time.  Cheap enough:
;;;; one line of input, two one-character attribute writes.
;;;;
;;;; CLEARING SWEEPS THE WHOLE INPUT REGION, not only the ranges last marked --
;;;; see CLEAR-PAREN-HIGHLIGHT for the bug that taught it -- and not the whole
;;;; transcript, which shook it on iOS.

(in-package #:lisp-listener)

(defun clear-paren-highlight (view pointer)
  "Remove the tint from the whole INPUT REGION, and any range marked.  Thread 1.

Not just from the ranges last marked, and that is the fix for a bug worth
remembering: a text view sets its typing attributes from the character at the
insertion point, so a character typed next to a tinted paren INHERITS the tint.
Those indices were never in the marks list, so clearing by range left them
coloured -- type `(room' and `room' came out tinted, and submitting the line
carried the colour up into the transcript for good.

One message over one range, and nothing else in the transcript uses a
background colour, so there is nothing to preserve."
  (let ((length (transcript-length pointer))
        (start (or (view-input-start view) 0)))
    ;; From the input region only, and the ranges marked: the tint is never
    ;; anywhere else -- the transcript gets text only through TRANSCRIPT-INSERT
    ;; and SUBMIT-INPUT, which both clear first.  Sweeping the WHOLE storage
    ;; on every keystroke made UIKit lay out the whole transcript again, and
    ;; with the caret on the bottom line the scroll position jumped about by
    ;; screenfuls while typing.
    (when (and length (< start length))
      (objc:invoke (transcript-storage pointer) "removeAttribute:range:"
                   (%ns-string-constant "NSBackgroundColorAttributeName")
                   (cons start (- length start))))
    (dolist (range (view-paren-marks view))
      (when (and length (< (car range) start) (<= (+ (car range) (cdr range)) length))
        (objc:invoke (transcript-storage pointer) "removeAttribute:range:"
                     (%ns-string-constant "NSBackgroundColorAttributeName")
                     range))))
  (setf (view-paren-marks view) '())
  view)

(defun mark-paren (view pointer offset kind)
  "Tint the one character at OFFSET, an index into the whole transcript."
  (let ((range (cons offset 1)))
    (objc:invoke (transcript-storage pointer) "addAttribute:value:range:"
                 (%ns-string-constant "NSBackgroundColorAttributeName")
                 (paren-background-color kind)
                 range)
    (push range (view-paren-marks view)))
  view)

(defun caret-paren (text offset)
  "The offset of the paren the caret is resting on, or NIL.

After a `)' first -- which is where the caret is when you have just typed one --
and otherwise before a `('.  Parens inside strings and comments are not parens
for this purpose, which is what CODE-POSITION-P answers."
  (cond ((and (plusp offset)
              (<= offset (length text))
              (char= (char text (1- offset)) #\))
              (code-position-p text (1- offset)))
         (1- offset))
        ((and (< offset (length text))
              (char= (char text offset) #\()
              (code-position-p text offset))
         offset)
        (t nil)))

(defun refresh-paren-highlight (view pointer)
  "Put the tint where the caret is now.  Thread 1; safe to call on every
keystroke and every selection change, and safe when there is no view at all."
  (handler-case
      (when (and view pointer)
        (clear-paren-highlight view pointer)
        (when *paren-highlight-enabled*
          (let* ((start (view-input-start view))
                 (caret (caret-index pointer)))
            (when (and start caret (>= caret start))
              (let* ((text (pending-input view pointer))
                     (offset (utf-16-offset->index text (- caret start)))
                     (paren (caret-paren text offset)))
                (when paren
                  (let ((partner (paren-match-offset text paren)))
                    (flet ((mark (index kind)
                             (mark-paren view pointer
                                         (+ start (utf-16-length (subseq text 0 index)))
                                         kind)))
                      (cond (partner
                             (mark paren :match)
                             (mark partner :match))
                            (t (mark paren :mismatch)))))))))))
    (error (condition)
      ;; A highlight is decoration.  It may not take the keystroke down with it.
      (note "paren highlight: ~a" condition)
      nil))
  view)
