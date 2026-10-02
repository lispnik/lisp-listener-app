;;;; src/impl.lisp -- SBCL or ECL, and the front end's half of the contract.
;;;;
;;;; The listener runs on SBCL on the Mac and on ECL on iOS, and this is the
;;;; only file in src/ that says which.  Everything here is either an SBCL
;;;; internal with an ECL counterpart, or a name the front end -- src/macos/
;;;; or src/ios/ -- promises to define.
;;;;
;;;; (The Gray stream package is the other difference, and it is settled in
;;;; package.lisp by a local nickname, because a nickname has to exist before
;;;; the reader meets the first qualified symbol.)

(in-package #:lisp-listener)

;;; SBCL and ECL ---------------------------------------------------------------

(defmacro with-invoke-debugger-hook ((hook) &body body)
  "Run BODY with the implementation's own debugger hook bound to HOOK.

Both SBCL and ECL null CL:*DEBUGGER-HOOK* before calling it, so that a hook
which itself errors cannot loop; a nested error raised while the debugger is
already up then finds it empty.  Each has a second hook that is not nulled, and
that is what catches the nested one.  See LISTENER-LOOP."
  `(let ((#+sbcl sb-ext:*invoke-debugger-hook*
          #+ecl ext:*invoke-debugger-hook*
          ,hook))
     ,@body))

(defmacro with-fresh-stack-top (() &body body)
  "Run BODY -- what is evaluated at a debugger prompt -- with SBCL's record of
where the current debugger's stack starts cleared.

INVOKE-DEBUGGER binds SB-DEBUG:*STACK-TOP-HINT* to the frame that failed and
calls the hook inside that binding, so a form evaluated at [1] runs inside it
too.  ERROR only sets the hint when it is NIL, so an error in that form would
reach level 2 carrying level 1's frame, and BACKTRACE-FRAMES would start there.
SBCL's own debugger binds it to NIL for the same reason.  ECL keeps no such
thing."
  #+sbcl `(let ((sb-debug:*stack-top-hint* nil)) ,@body)
  #-sbcl `(progn ,@body))

(defun backtrace-frames (count)
  "Up to COUNT frames beneath the debugger, innermost first.  Each is
(CALL . LOCALS): CALL a list whose first element names the function, and
LOCALS the frame's valid local variables as (SYMBOL . VALUE) -- which exist
only here, while the stack does, so they are taken now or never.

On SBCL it starts from the frame INVOKE-DEBUGGER resolved before calling the
hook -- SB-DEBUG:*STACK-TOP-HINT*, the frame that signalled -- which skips
INVOKE-DEBUGGER and the hooks.  Not :FROM :DEBUGGER-FRAME, which is right only
inside SBCL's own debugger: outside it, that falls back to the most recent
INTERRUPTED frame on the stack, and at a second debugger level the first
error's trap is still there.  An error typed at [1] after an unbound variable
got the unbound variable's backtrace.

ECL has no such option, so its frames are cut by hand, after the listener's
debugger hook.  Not after INVOKE-DEBUGGER, which is what this used to look for:
that is not on ECL's frame stack at all, so nothing was cut and every backtrace
began with BACKTRACE-FRAMES and the listener's own debugger.  Only the function
is known -- ECL's frame stack keeps neither the arguments nor the locals."
  #+sbcl
  (let ((frames '()))
    (sb-debug:map-backtrace
     (lambda (frame)
       (push (cons (sb-debug::frame-call-as-list frame sb-debug::*default-argument-limit*)
                   (frame-locals frame))
             frames))
     :count count
     :from (if (sb-di:frame-p sb-debug:*stack-top-hint*)
               sb-debug:*stack-top-hint*
               (sb-debug::backtrace-start-frame :debugger-frame)))
    (nreverse frames))
  #+ecl
  (let* ((frames (loop for index from (si::ihs-top) downto 1
                       collect (list (list (ecl-function-name (si::ihs-fun index))))))
         (debugger (position-if (lambda (function)
                                  (member function '(invoke-debugger
                                                     listener-debugger-hook)))
                                frames :key #'caar)))
    (subseq frames (if debugger (1+ debugger) 0)
            (min (length frames) (+ (if debugger (1+ debugger) 0) count)))))

#+sbcl
(defun frame-locals (frame)
  "FRAME's local variables that hold a value where it stopped, as
(SYMBOL . VALUE), in SBCL's order.  What SBCL's own LIST-LOCALS prints, less
the &MORE bookkeeping variables, which are the compiler's rather than yours.
NIL when the function was compiled without debug information."
  (ignore-errors
   (let ((function (sb-di:frame-debug-fun frame))
         (location (sb-di:frame-code-location frame)))
     (when (sb-di:debug-var-info-available function)
       (multiple-value-bind (more-context more-count)
           (sb-di:debug-fun-more-args function)
         (loop for variable in (sb-di:ambiguous-debug-vars function "")
               when (and (not (eq variable more-context))
                         (not (eq variable more-count))
                         (eq :valid (sb-di:debug-var-validity variable location)))
                 collect (cons (sb-di:debug-var-symbol variable)
                               (sb-di:debug-var-value variable frame))))))))

(defun internal-frame-p (call)
  "Whether CALL, a frame's call list, is the implementation evaluating a form
typed at the prompt -- its evaluator, its compile-on-the-fly, EVAL -- rather
than the code that failed.  By the PACKAGE of the function's name, so SBCL's
next rearrangement of its evaluator does not need a new list here.  A local
function counts by the function it is in: (FLET G :IN SB-C::%COMPILE-IN-LEXENV)."
  (let* ((name (and (consp call) (first call)))
         (symbol (cond ((symbolp name) name)
                       ((consp name)
                        (let ((in (member :in name)))
                          (and in (symbolp (second in)) (second in))))))
         (package (and symbol (symbol-package symbol))))
    (and symbol
         (or (eq symbol 'eval)
             (and package
                  (member (package-name package)
                          #+sbcl '("SB-IMPL" "SB-C" "SB-INT" "SB-EVAL" "SB-KERNEL")
                          #+ecl '("SI" "SYSTEM")
                          #-(or sbcl ecl) '()
                          :test #'string=))))))

#+ecl
(defun ecl-function-name (function)
  (or (ignore-errors
       (if (functionp function)
           (nth-value 2 (function-lambda-expression function))
           function))
      function))

(defun restart-interactive-function (restart)
  "RESTART's interactive function, or NIL.  An internal on both, guarded:
losing it costs an ellipsis in the restart list and nothing else."
  (ignore-errors
   #+sbcl (sb-kernel::restart-interactive-function restart)
   #+ecl (si::restart-interactive-function restart)))

(defun macro-lambda-list (symbol)
  "The lambda list of the macro SYMBOL names, or NIL.  Asked by the indenter,
which wants to know whether there is an &BODY in it."
  (ignore-errors
   #+sbcl (sb-kernel:%fun-lambda-list (macro-function symbol))
   #+ecl (ext:function-lambda-list symbol)))

(defun exit-process (code)
  "Leave now, without unwinding: the caller has nothing left to clean up and a
thread still blocked in READ would otherwise hold the process open."
  #+sbcl (sb-ext:exit :code code :abort t)
  #+ecl (ext:quit code))

(defun getenv (name)
  "The environment variable NAME, or NIL.  Not UIOP's: an iOS app is linked
without ASDF, and so without UIOP."
  #+sbcl (sb-ext:posix-getenv name)
  #+ecl (ext:getenv name))

(defun safepoint-build-p ()
  "True where stopping the world cannot kill the process from a libdispatch
thread.

On SBCL that means a build --with-sb-safepoint: such a build stops the world by
polling rather than by signalling, which is what makes it safe for Lisp to run
on a thread Darwin will not let anyone signal.  AppKit reaches libdispatch on
its own, so a Cocoa application wants one whether or not it uses GCD itself.
See lispnik/objc's doc/sbcl-libdispatch-safepoint.md.

ECL never signals a thread to collect garbage, so the question does not arise."
  #+sbcl (and (member :sb-safepoint *features*) t)
  #-sbcl t)

;;; The front end ----------------------------------------------------------------
;;;
;;; Defined in src/macos/ or src/ios/, which load after everything here.  The
;;; core calls them; neither front end is loaded at the same time as the other.

(declaim (ftype function
                ;; An NSColor or UIColor for a kind of transcript text, and the
                ;; monospaced font it is set in.
                transcript-color transcript-font
                ;; The run loop modes a hop to the main thread is queued in.
                main-thread-run-loop-modes
                ;; Where the history file lives, or NIL for nowhere.
                history-directory
                ;; The tint for a matched (:MATCH) or unmatched (:MISMATCH)
                ;; parenthesis, and the chance to rebuild cached key commands
                ;; after *PAREDIT-KEYS* changes.
                paren-background-color invalidate-key-commands
                ;; The restarts, on screen: build and show, take down, ask; and
                ;; ask for the value a restart like USE-VALUE wants.
                show-restarts-panel hide-restarts-panel restarts-panel-visible-p
                request-restart-value
                ;; The history list, the same three ways.
                show-history-popup hide-history-popup history-popup-visible-p
                ;; Which listener a menu item or a key means.
                current-listener
                ;; The canvas (src/canvas.lisp): :APPKIT or :UIKIT, for the
                ;; painter; put it on screen, with the keyboard or without;
                ;; take it down; ask; and repaint it, showing it if need be.
                canvas-toolkit show-canvas hide-canvas canvas-visible-p
                redisplay-canvas
                ;; ...write it to a PNG file; and the directory a file with no
                ;; directory of its own is saved in.
                save-canvas-png documents-directory
                ;; LISTENER-TEXT-VIEW's slot accessors.  The class is the front
                ;; end's -- its superclass is NSTextView or UITextView -- and
                ;; the transcript in the core reads and writes its slots.
                view-input-start (setf view-input-start)
                view-history (setf view-history)
                view-history-index (setf view-history-index)
                view-paren-marks (setf view-paren-marks)))

;;; Defined later in the core than the file that first calls them.  A :SERIAL
;;; system tolerates a forward reference; the compile check, which compiles each
;;; file on its own, reports one as a style warning without these.
(declaim (ftype function refresh-paren-highlight clear-paren-highlight))
