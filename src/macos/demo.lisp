;;;; src/macos/demo.lisp -- a scripted session, photographed frame by frame.
;;;;
;;;; LISP_LISTENER_DEMO=<directory> plays a session in the real application --
;;;; every key typed through the same hook a keypress reaches -- and photographs
;;;; the window after each step.  It writes frames/NNNNN.png, frames.txt (an
;;;; ffmpeg concat list with how long each frame shows) and captions.tsv (start,
;;;; end, text), and leaves.  tools/make-demo.sh turns those into a captioned
;;;; video; `make demo' does both.
;;;;
;;;; Photographed, not screen-recorded, for the reason the screenshots are:
;;;; the window draws itself into a bitmap, which needs no Screen Recording
;;;; permission and so runs on a CI runner.  The history list is a sheet, a
;;;; window of its own, so it is composited into the frame where it sits.
;;;;
;;;; A demo is also a test nobody wrote: the first version of this found that
;;;; every string typed at the listener came out wrong.  So it waits for each
;;;; answer before going on, and says so and stops if one does not come.

(in-package #:lisp-listener)

(defvar *demo-directory* nil)
(defvar *demo-frames* '())      ; (path . seconds), newest first
(defvar *demo-clock* 0d0)       ; seconds of video so far
(defvar *demo-captions* '())    ; (start end text), newest first
(defvar *demo-caption* nil)     ; (start . text) of the caption showing now
(defvar *demo-count* 0)

(defun demo-path (name)
  (namestring (merge-pathnames name *demo-directory*)))

(defun demo-overlay (window-png panel window)
  "Put PANEL -- a separate window -- into WINDOW-PNG where it sits on screen."
  (let* ((scale (objc:invoke window "backingScaleFactor"))
         (wf (objc:invoke window "frame"))
         (pf (objc:invoke panel "frame"))
         (sheet (not (cffi:null-pointer-p (objc:invoke panel "sheetParent"))))
         ;; A sheet hangs from the foot of the title bar, centred; its reported
         ;; frame put it a hundred points lower than it is drawn.
         (x (round (* scale (if sheet
                                (/ (- (aref wf 2) (aref pf 2)) 2)
                                (- (aref pf 0) (aref wf 0))))))
         (y (round (* scale (if sheet
                                (- (aref wf 3)
                                   (aref (objc:invoke window "contentLayoutRect") 3))
                                (- (+ (aref wf 1) (aref wf 3)) (+ (aref pf 1) (aref pf 3)))))))
         (panel-png (demo-path "panel.png")))
    (write-window-png panel panel-png)
    (uiop:run-program (list "magick" window-png panel-png
                            "-geometry" (format nil "+~d+~d" x y) "-composite" window-png)
                      :output nil :error-output t)))

(defun demo-frame (seconds &optional (listener *listener*))
  "Photograph the window, to be shown for SECONDS."
  (pump 0.02d0)
  (let ((path (demo-path (format nil "frames/~5,'0d.png" (incf *demo-count*))))
        (window (listener-window listener)))
    (write-window-png window path)
    (when (history-popup-visible-p listener)
      (demo-overlay path (listener-history-panel listener) window))
    (push (cons path seconds) *demo-frames*)
    (incf *demo-clock* seconds)))

(defun demo-caption (text)
  (when *demo-caption*
    (push (list (car *demo-caption*) *demo-clock* (cdr *demo-caption*)) *demo-captions*))
  (setf *demo-caption* (and text (cons *demo-clock* text))))

(defun demo-view () (listener-view *listener*))

(defun demo-type (text &key (per-key 0.055d0))
  "Type TEXT a key at a time, through the hook a keypress reaches."
  (loop for ch across text
        do (objc:invoke (demo-view) "insertText:replacementRange:" (string ch)
                        (cons #x7FFFFFFFFFFFFFFF 0))
           (demo-frame per-key)))

(defun demo-key (selector &optional (seconds 0.3d0))
  (objc:invoke (demo-view) selector (cffi:null-pointer))
  (demo-frame seconds))

(defun demo-expect (ok what)
  "Stop the demo, loudly, when what it shows did not happen."
  (unless ok
    (note "demo: ~a did not happen; stopping" what)
    (finish-and-exit 1)))

(defun demo-return (marker &key (hold 1.4d0))
  "Press Return and let the answer arrive -- until MARKER appears after it."
  (let ((before (length (transcript-text *listener*))))
    (objc:invoke (demo-view) "insertNewline:" (cffi:null-pointer))
    (demo-expect (wait-for (lambda () (search marker (transcript-text *listener*)
                                              :start2 before))
                           :timeout 15)
                 (format nil "~s after Return" marker))
    (pump-for 0.15d0)
    (demo-frame hold)))

(defun demo-at-prompt ()
  (demo-expect (wait-for (lambda () (waiting-at-top-level-p *listener*)) :timeout 15)
               "the top-level prompt"))

(defun demo-pane-up ()
  (demo-expect (wait-for (lambda () (restarts-panel-visible-p *listener*)) :timeout 15)
               "the debugger pane")
  (pump-for 0.3d0))

(defun demo-press (characters)
  (press-key-equivalent (listener-window *listener*) characters))

(defun demo-write-lists ()
  "The ffmpeg concat list -- the last frame named twice, as ffmpeg wants -- and
the captions."
  (with-open-file (out (demo-path "frames.txt") :direction :output :if-exists :supersede)
    (let ((frames (reverse *demo-frames*)))
      (dolist (f frames)
        (format out "file '~a'~%duration ~,3f~%" (car f) (cdr f)))
      (format out "file '~a'~%" (car (car (last frames))))))
  (with-open-file (out (demo-path "captions.tsv") :direction :output :if-exists :supersede)
    (dolist (c (reverse *demo-captions*))
      (format out "~,3f~c~,3f~c~a~%" (first c) #\Tab (second c) #\Tab (third c)))))

(defun run-demo ()
  "Play the session, write the frames and the lists, and leave."
  (setf *demo-directory*
        (uiop:ensure-directory-pathname (uiop:getenv "LISP_LISTENER_DEMO")))
  (ensure-directories-exist (merge-pathnames "frames/" *demo-directory*))
  (let* ((listener *listener*) (window (listener-window listener)))
    ;; Big enough for the pane and the transcript together.
    (objc:invoke window "setFrame:display:" (vector 120d0 120d0 860d0 700d0) t)
    (demo-at-prompt) (pump-for 0.5d0)

    (demo-caption "Type a form and press Return: its value comes back in the same window")
    (demo-frame 1.2d0)
    (demo-type "(+ 1 2)") (demo-return "3")
    (demo-type "(dotimes (i 3) (format t \"tick ~d~%\" i))")
    (demo-return "NIL")

    (demo-caption "Parens and quotes close themselves, and the matching paren is tinted")
    (demo-type "(mapcar (lambda (x) (* x x)) '(1 2 3 4))" :per-key 0.07d0)
    (demo-frame 1.0d0)
    (demo-return "16")

    (demo-caption "Option-Return starts a new, indented line; Return evaluates the whole form")
    (demo-type "(defun greet (name)")
    (demo-key "insertNewlineIgnoringFieldEditor:" 0.5d0)
    (demo-type "(let ((n (length name)))")
    (demo-key "insertNewlineIgnoringFieldEditor:" 0.5d0)
    (demo-type "(format nil \"Hello, ~a (~d letters)\" name n)))")
    (demo-frame 1.2d0)
    (demo-return "GREET")
    (demo-type "(greet \"Lisp\")") (demo-return "letters" :hold 1.8d0)

    (demo-caption "⌘. interrupts a form that is still running")
    (demo-type "(loop (sleep 0.1))")
    (objc:invoke (demo-view) "insertNewline:" (cffi:null-pointer))
    (demo-frame 0.8d0) (demo-frame 0.8d0)
    (abort-evaluation listener)
    (demo-expect (wait-for (lambda () (search "Aborted." (transcript-text listener)))
                           :timeout 10)
                 "the interrupt")
    (demo-at-prompt) (pump-for 0.2d0) (demo-frame 1.4d0)

    (demo-caption "⌘R searches everything you have typed, and puts your choice back at the prompt")
    ;; Long enough for the sheet to finish sliding down: photographed on its
    ;; way, it sat a hundred points below the title bar it hangs from.
    (open-history-popup listener) (pump-for 1.0d0) (demo-frame 1.2d0)
    (loop for i from 1 to 5
          do (type-history-query (subseq "greet" 0 i) listener) (pump 0.05d0)
             (demo-frame 0.18d0))
    (demo-frame 1.4d0)
    (choose-history-row listener 0) (pump-for 0.3d0) (demo-frame 1.2d0)
    (demo-return "letters")

    (demo-caption "An error docks the debugger under the transcript")
    (demo-type "(defun average (xs) (let ((total (reduce #'+ xs))) (float (/ total (length xs)))))"
               :per-key 0.035d0)
    (demo-return "AVERAGE" :hold 0.6d0)
    (demo-type "(average '())")
    (objc:invoke (demo-view) "insertNewline:" (cffi:null-pointer))
    (demo-pane-up) (demo-frame 2.6d0)

    (demo-caption "Each frame of the backtrace opens to show its local variables")
    (let* ((items (getf (pane-views listener) :backtrace-items))
           (outline (objc:invoke (getf (pane-views listener) :backtrace) "documentView"))
           (frame (position-if (lambda (f) (search "AVERAGE" (backtrace-frame-line f)))
                               (backtrace-items-frames items))))
      (demo-expect frame "a frame for AVERAGE")
      (objc:invoke outline "expandItem:" (aref (backtrace-items-roots items) frame)))
    (pump-for 0.2d0) (demo-frame 2.6d0)

    (demo-caption "⌘ and a restart's number takes it -- typed at the prompt, where you can see it")
    (demo-press (format nil "~d" (toplevel-restart-row listener)))
    (demo-at-prompt) (pump-for 0.3d0) (demo-frame 2.0d0)

    (demo-caption "A restart that needs a value asks for it in the pane")
    (demo-type "(+ 1 *no-such-variable*)")
    (objc:invoke (demo-view) "insertNewline:" (cffi:null-pointer))
    (demo-pane-up) (demo-frame 1.8d0)
    (demo-press "1") (demo-frame 1.2d0)
    (let ((field (getf (pane-views listener) :value-field)))
      (loop for i from 1 to 2
            do (objc:invoke field "setStringValue:" (subseq "41" 0 i)) (demo-frame 0.25d0)))
    (demo-frame 1.2d0)
    (demo-caption "Return sends it as `1 41': that restart, with that value")
    (objc:invoke (listener-restarts-invoke listener) "performClick:" nil)
    (demo-at-prompt) (pump-for 0.3d0) (demo-frame 2.6d0)

    (demo-caption "An error at a debugger prompt opens the next level down")
    (demo-type "(car 'oops)")
    (objc:invoke (demo-view) "insertNewline:" (cffi:null-pointer))
    (demo-pane-up) (demo-frame 1.4d0)
    (demo-type "(/ 1 0)")
    (objc:invoke (demo-view) "insertNewline:" (cffi:null-pointer))
    (demo-expect (wait-for (lambda () (search "[2]" (last-line (transcript-text listener))))
                           :timeout 15)
                 "a second debugger level")
    (pump-for 0.4d0) (demo-frame 2.6d0)
    (demo-press "0") (demo-at-prompt) (pump-for 0.3d0) (demo-frame 1.8d0)

    (demo-caption "⌘K clears the transcript")
    (clear-transcript listener) (pump-for 0.3d0) (demo-frame 2.0d0)
    (demo-caption nil)

    (demo-write-lists)
    (note "demo: ~d frames, ~,1f seconds" *demo-count* *demo-clock*)
    (finish-and-exit 0)))
