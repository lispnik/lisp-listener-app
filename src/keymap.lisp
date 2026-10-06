;;;; src/keymap.lisp -- the switches that are the Listener's own.
;;;;
;;;; The paredit key table, *PAREDIT-ENABLED*, *AUTO-INDENT-ENABLED* and
;;;; (SETF PAREDIT-KEY) are sexp-edit's (vendor/sexp-edit), shared with Heml:
;;;; this package uses that one, so they are read and set here by the same
;;;; names as before.  What is left is what only a Listener has, and the two
;;;; places the library hands back to its front end.

(in-package #:lisp-listener)

(defparameter *paren-highlight-enabled* t
  "Whether the parenthesis under the caret and its partner are tinted.")

(defparameter *arglist-hints-enabled* t
  "Whether the lambda list of the call being typed is shown, with the argument
the caret is on picked out.  See src/arglist.lisp.")

;;; The iOS front end builds UIKeyCommands once and keeps them; a rebinding has
;;; to make it build them again.  INVALIDATE-KEY-COMMANDS is each front end's,
;;; defined later, so the hook holds its name.
(pushnew 'invalidate-key-commands *keys-changed-functions*)

;;; A command that signals declines, and the key does what it would have done
;;; without paredit; the condition goes to the log.
(setf *command-error-function*
      (lambda (command condition)
        (note "paredit ~a: ~a" command condition)))
