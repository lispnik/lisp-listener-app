;;;; src/package.lisp
;;;;
;;;; One package.  OBJC is not :USEd: it exports INVOKE, DESCRIPTION, RELEASE
;;;; and RETAIN, and a listener is exactly the program where an accidental
;;;; capture of one of those is hardest to see.
;;;;
;;;; GRAY-STREAMS is whichever Gray stream package this Lisp has: SB-GRAY on
;;;; SBCL, GRAY on ECL.  Every other SBCL/ECL difference is in impl.lisp; this
;;;; one has to be here, because the nickname must exist before the reader
;;;; meets the first GRAY-STREAMS: symbol.

(defpackage #:lisp-listener
  (:use #:cl)
  (:local-nicknames (#:gray-streams #+sbcl #:sb-gray #+ecl #:gray))
  (:export
   ;; Entry points.
   #:main
   #:run-listener
   ;; The pieces, for a caller who wants the view somewhere else.
   #:make-listener
   #:make-listener-view
   #:make-listener-window
   #:listener
   #:listener-p
   #:listener-view
   #:listener-window
   #:listener-thread
   #:*listener*
   ;; More than one at a time.
   #:new-listener
   #:*listeners*
   #:current-listener
   ;; iOS.
   #:ios-start
   ;; Control.
   #:abort-evaluation
   #:clear-transcript
   #:*paredit-enabled*
   #:*paredit-keys*
   #:paredit-key
   #:*paredit-commands*
   #:*paren-highlight-enabled*
   #:*history-popup-rows*
   #:open-history-popup
   #:*restarts-panel-enabled*
   #:*backtrace-enabled*
   #:*backtrace-frames*
   #:safepoint-build-p
   ;; The examples that ship in the image.
   #:examples
   #:example
   #:example-source))

;;; CANVAS is the other package, and it holds nothing but names: the drawing
;;; vocabulary a person types at the prompt.  It uses nothing, so that LINE and
;;; LEFT and KEY cannot collide with anything here; every one of them is defined
;;; in src/canvas.lisp, from inside LISP-LISTENER, as CANVAS:LINE and so on.
;;; INSTALL-USER-VOCABULARY imports them into CL-USER when a listener starts.
(defpackage #:canvas
  (:use)
  (:export
   ;; The canvas itself.
   #:show #:hide #:clear #:background
   ;; The pen.
   #:color #:hue #:pen
   ;; Shapes.  The canvas runs from -100 to 100 each way, y upwards.
   #:line #:dot #:circle #:rect #:box #:text #:plot #:curve
   ;; A turtle.
   #:forward #:back #:left #:right #:pen-up #:pen-down #:home #:move-to
   ;; Animation and games.
   #:frame #:wait #:key))
