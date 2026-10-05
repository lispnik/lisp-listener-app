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

(defparameter *demo-window-width* 860d0)
(defparameter *demo-window-height* 600d0)
(defvar *demo-directory* nil)
(defvar *demo-frames* '())      ; (path . seconds), newest first
(defvar *demo-clock* 0d0)       ; seconds of video so far
(defvar *demo-captions* '())    ; (start end text), newest first
(defvar *demo-caption* nil)     ; (start . text) of the caption showing now
(defvar *demo-count* 0)
(defvar *demo-overlays* '()
  "Functions answering another window to lay over the listener's picture when
it is up.  src/macos/heml-demo.lisp adds heml's.")

(defun demo-path (name)
  (namestring (merge-pathnames name *demo-directory*)))

(defun demo-overlay (window-png panel window &optional panel-png)
  "Put PANEL -- a separate window -- into WINDOW-PNG where it sits on screen.
PANEL-PNG, if given, is the picture of it to use: one with a sheet of its own
already composited in."
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
         (written (or panel-png (demo-path "panel.png"))))
    (unless panel-png
      (write-window-png panel written))
    (uiop:run-program (list "magick" window-png written
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
    ;; The canvas is a window of its own too; for the demo it sits over the
    ;; listener's lower right corner, and is composited in where it sits.
    (when (canvas-visible-p)
      (demo-overlay path *canvas-window* window))
    ;; An inspector is another, laid over the listener for the demo.
    (dolist (inspector (reverse *inspectors*))
      (let ((inspector-window (inspector-part inspector :window)))
        (when (and (live-pointer-p inspector-window)
                   (objc:invoke-bool inspector-window "isVisible"))
          ;; With its own sheet in it, if it has one up: a sheet is placed
          ;; against the window it hangs from, so it goes into that first.
          (let ((inspector-png (demo-path "inspector.png")))
            (write-window-png inspector-window inspector-png)
            (when (views-sheet-open-p inspector)
              (demo-overlay inspector-png (inspector-part inspector :sheet) inspector-window))
            (demo-overlay path inspector-window window inspector-png)))))
    ;; And so is Settings, which the demo likewise puts over the listener.
    (when (and (live-pointer-p *preferences-window*)
               (objc:invoke-bool *preferences-window* "isVisible"))
      (demo-overlay path *preferences-window* window))
    (dolist (overlay *demo-overlays*)
      (let ((other (funcall overlay)))
        (when (and (live-pointer-p other) (objc:invoke-bool other "isVisible"))
          (demo-overlay path other window))))
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

(defparameter *demo-canvas-size* 330d0)

(defun demo-place-canvas (window)
  "Make the canvas's window now, small and over the listener's lower right
corner, so that the first shape drawn finds it where the frames expect it."
  (unless (live-pointer-p *canvas-window*)
    (build-canvas-window))
  (let ((frame (objc:invoke window "frame"))
        (size *demo-canvas-size*))
    (objc:invoke *canvas-window* "setFrame:display:"
                 (objc:invoke *canvas-window* "frameRectForContentRect:"
                              (vector (- (+ (aref frame 0) (aref frame 2)) size 16d0)
                                      (+ (aref frame 1) 16d0)
                                      size size))
                 t)))

(defun demo-drawn (count what)
  "Wait for COUNT shapes on the canvas, painted, and the prompt back."
  (let ((paints *canvas-paints*))
    (demo-expect (wait-for (lambda () (and (= count (length (canvas-contents)))
                                           (canvas-visible-p)
                                           (> *canvas-paints* paints)))
                           :timeout 20)
                 what))
  (demo-at-prompt)
  (pump-for 0.3d0))

(defun demo-play-snake (listener)
  "Play Snake with a script: a frame of video for each turn of the game, and a
key at the turns that need one.  The game runs five times slower than it is
shown, which is the time a photograph takes -- and when a photograph takes
longer than that and a turn goes by unseen, the frame that is taken stands for
both, and a key that was due is pressed late rather than never."
  (let ((keys (list (cons 7 :up) (cons 12 :left) (cons 24 :down) (cons 36 :right)))
        (start *canvas-frames*)
        (seen 0))
    (setf *canvas-time-scale* 5)
    (run-example-in-listener listener "snake")
    (unwind-protect
         (loop
           (demo-expect (wait-for (lambda ()
                                    (or (> (- *canvas-frames* start) seen)
                                        (waiting-at-top-level-p listener)))
                                  :timeout 20)
                        "the next turn of Snake")
           (let ((now (- *canvas-frames* start)))
             (when (= now seen)
               (return))                  ; the prompt is back: game over
             (loop while (and keys (>= now (car (first keys))))
                   do (canvas-push-key (cdr (pop keys))))
             (pump 0.05d0)
             (demo-frame (* 0.15d0 (- now seen)))
             (setf seen now)))
      (setf *canvas-time-scale* 1))
    (pump-for 0.3d0)
    (demo-frame 2.4d0)))

(defun demo-heart (&optional (count 60))
  "A heart, as canvas points, for the demo's mouse to draw."
  (loop for i from 0 to count
        for a = (* 2 pi (/ i count))
        collect (cons (* 4.6 16 (expt (sin a) 3))
                      (+ 8 (* 4.6 (- (* 13 (cos a)) (* 5 (cos (* 2 a)))
                                     (* 2 (cos (* 3 a))) (cos (* 4 a))))))))

(defun demo-doodle (listener)
  "The doodle example, with the mouse drawn for it: a press, a drag through
each point of a heart, a release -- as events to the canvas's view, which is
how AppKit would deliver them -- and a frame of video for each."
  (run-example-in-listener listener "doodle")
  (demo-expect (wait-for (lambda () (and (= 1 (length (canvas-contents)))
                                         (canvas-visible-p)))
                         :timeout 15)
               "the doodle to start")
  (pump-for 0.3d0)
  (demo-frame 1.0d0)
  (let* ((view (canvas-view-pointer))
         (bounds (objc:invoke view "bounds"))
         (cx (/ (aref bounds 2) 2)) (cy (/ (aref bounds 3) 2))
         (unit (/ (min (aref bounds 2) (aref bounds 3)) 200))
         (points (demo-heart)))
    (flet ((event (type point)
             (canvas-mouse-test-event type (+ cx (* unit (car point)))
                                      (+ cy (* unit (cdr point))))))
      (objc:invoke view "mouseDown:" (event 1 (first points)))
      (dolist (point (rest points))
        (let ((lines (length (canvas-contents))))
          (objc:invoke view "mouseDragged:" (event 6 point))
          ;; The doodle looks fifty times a second: wait for it to have seen
          ;; this point, so that every one of them is a line.
          (wait-for (lambda () (> (length (canvas-contents)) lines)) :timeout 2)
          (demo-frame 0.05d0)))
      (objc:invoke view "mouseUp:" (event 2 (first (last points))))))
  ;; Escape is how a doodle is given up before its time.
  (canvas-push-key :escape)
  (demo-at-prompt)
  (pump-for 0.3d0)
  (demo-frame 2.4d0))

(defun demo-await-inspector (listener what)
  "Wait for the one inspector the demo has open, and lay its window over the
listener's so that it is in the picture."
  (demo-expect (wait-for (lambda () (newest-inspector-ready-p 1)) :timeout 20) what)
  (let* ((inspector (first *inspectors*))
         (frame (objc:invoke (listener-window listener) "frame")))
    (objc:invoke (inspector-part inspector :window) "setFrame:display:"
                 (vector (+ (aref frame 0) 16d0) (+ (aref frame 1) 16d0)
                         (- (aref frame 2) 32d0) (- (aref frame 3) 76d0))
                 t)
    (refresh-inspector inspector)
    (pump-for 0.4d0)
    inspector))

(defun demo-inspector (listener)
  "The inspector: two views of a byte vector, an option, and the thermal
example's contributed view and controls."
  (demo-caption "(inspect x) opens an inspector: two views of one thing, side by side")
  (demo-type "(defparameter *bytes* (coerce (loop for i below 256 collect (mod (* i i) 251)) '(vector (unsigned-byte 8))))"
             :per-key 0.03d0)
  (demo-return "*BYTES*" :hold 0.6d0)
  (demo-type "(inspect *bytes*)")
  (objc:invoke (demo-view) "insertNewline:" (cffi:null-pointer))
  (let ((inspector (demo-await-inspector listener "an inspector on the bytes")))
    (demo-frame 3.2d0)
    (demo-caption "A view's options are its own: here, how many bins")
    (let ((slider (first (getf (inspector-pane-parts inspector 0) :option-controls))))
      (dolist (bins '(26 20 14 8 12 16))
        (objc:invoke slider "setDoubleValue:" (float bins 1d0))
        (send-control-action slider)
        (demo-expect (wait-for (lambda () (eql bins (inspector-drawing-count inspector 0 :rect)))
                               :timeout 10)
                     (format nil "a histogram of ~d bins" bins))
        (pump 0.1d0)
        (demo-frame 0.45d0)))
    (demo-frame 1.2d0)
    ;; The pointer across the drawing: each bin says what it holds.
    (demo-caption "Over a drawing, the pointer says what is under it")
    (let* ((window (inspector-part inspector :window))
           (drawing (getf (inspector-pane-parts inspector 0) :drawing))
           (object (getf (inspector-pane-parts inspector 0) :drawing-object))
           (bounds (objc:invoke drawing "bounds")))
      (dolist (fraction '(0.18d0 0.3d0 0.42d0 0.55d0 0.68d0 0.8d0))
        (let ((point (objc:invoke drawing "convertPoint:toView:"
                                  (vector (* fraction (aref bounds 2)) (* 0.62d0 (aref bounds 3)))
                                  nil))
              (before (drawing-view-readout object)))
          (objc:invoke drawing "mouseMoved:"
                       (window-mouse-test-event window 5 (aref point 0) (aref point 1)))
          (demo-expect (wait-for (lambda () (and (drawing-view-readout object)
                                                 (not (equal before (drawing-view-readout object)))))
                                 :timeout 10)
                       "a readout")
          (pump 0.05d0)
          (demo-frame 0.6d0)))
      (objc:invoke drawing "mouseExited:" (window-mouse-test-event window 5 0d0 0d0)))
    ;; Every view there is, and why the ones that do not apply do not.
    (demo-caption "All Views lists every view there is, and says why one does not apply")
    (objc:invoke (inspector-part inspector :all-views-button) "performClick:" nil)
    (demo-expect (wait-for (lambda () (views-sheet-open-p inspector)) :timeout 10) "the views sheet")
    (pump-for 0.6d0)
    (demo-frame 2.0d0)
    (let ((table (inspector-part inspector :sheet-table)))
      ;; Rows in sight: a table scrolled in a window that is not key is
      ;; photographed with its header over the rows.
      (dolist (title '("Cons" "Grid"))
        (let ((row (views-sheet-row-of inspector title)))
          (select-restart-row table row))
        (pump 0.1d0)
        (demo-frame 1.8d0)))
    (hide-views-sheet inspector)
    (pump-for 0.6d0)
    (demo-frame 0.8d0))
  (hide-inspectors)
  (pump-for 0.3d0)
  (demo-caption "Anyone can contribute a view, and controls: this hot plate is forty lines")
  (run-example-in-listener listener "thermal")
  (let* ((inspector (demo-await-inspector listener "an inspector on the plate"))
         (slider (second (inspector-part inspector :control-views))))
    (demo-at-prompt)
    (demo-frame 2.8d0)
    (demo-caption "A slider changes the object, and every view of it is drawn again")
    (dolist (source '(75 60 45 30 15 35 60 85))
      (objc:invoke slider "setDoubleValue:" (float source 1d0))
      (send-control-action slider)
      (demo-expect (wait-for (lambda ()
                               (eql (float source 1d0)
                                    (control-model-value
                                     (second (model-controls (inspector-model inspector))))))
                             :timeout 10)
                   (format nil "the plate's source at ~d" source))
      (pump 0.15d0)
      (demo-frame 0.5d0))
    (demo-frame 1.8d0))
  (hide-inspectors)
  (pump-for 0.3d0))

(defun demo-settings (listener)
  "Settings, and the size of the type from the View menu."
  (let ((frame (objc:invoke (listener-window listener) "frame")))
    (demo-expect (press-menu-item "Lisp Listener" "Settings…") "Settings…")
    (objc:invoke *preferences-window* "setFrameTopLeftPoint:"
                 (vector (+ (aref frame 0) 240d0)
                         (- (+ (aref frame 1) (aref frame 3)) 110d0)))
    (pump-for 0.3d0)
    (demo-frame 2.0d0)
    (dotimes (i 3)
      (press-menu-item "View" "Bigger")
      (pump 0.1d0)
      (demo-frame 0.5d0))
    (demo-frame 1.6d0)
    (dotimes (i 3)
      (press-menu-item "View" "Smaller")
      (pump 0.1d0)
      (demo-frame 0.3d0))
    (hide-preferences-window)
    (pump-for 0.2d0)
    (demo-frame 0.8d0)))

(defun demo-canvas (listener)
  "The canvas, the examples and a game."
  (demo-place-canvas (listener-window listener))
  (demo-caption "There is a canvas to draw on: (circle 0 0 60) opens it")
  (demo-type "(circle 0 0 60)")
  (objc:invoke (demo-view) "insertNewline:" (cffi:null-pointer))
  (demo-drawn 1 "a circle on the canvas")
  (demo-frame 1.8d0)
  (demo-caption "A turtle that walks a little further every time it turns")
  (demo-type "(dotimes (i 140) (hue (/ i 140)) (forward i) (right 89))" :per-key 0.035d0)
  (objc:invoke (demo-view) "insertNewline:" (cffi:null-pointer))
  (demo-drawn 141 "the spiral")
  (demo-frame 2.8d0)
  (demo-caption "Short examples come with it, in the Examples menu")
  (run-example-in-listener listener "tree")
  (demo-drawn 511 "the tree")
  (demo-frame 2.4d0)
  (run-example-in-listener listener "mandelbrot")
  (demo-expect (wait-for (lambda () (and (> (length (canvas-contents)) 600)
                                         (waiting-at-top-level-p listener)))
                         :timeout 30)
               "the Mandelbrot set")
  (pump-for 0.4d0)
  (demo-frame 2.8d0)
  (demo-caption "(pointer) is the mouse: a doodle draws where it goes")
  (demo-doodle listener)
  (demo-caption "(frame ...) animates and (key) reads the arrows, so Snake is forty lines")
  (demo-play-snake listener)
  (hide-canvas)
  (pump-for 0.3d0))

(defparameter *demo-turtle-gallery*
  '(("snowflake" "(snowflake 4)")
    ("hilbert" "(hilbert 5)")
    ("arrowhead" "(arrowhead 7)")
    ("plant" "(plant 5)")
    ("rosette" "(progn (clear) (pen 1.2) (dotimes (i 36) (hue (/ i 36) 0.7 1) (arc 70 60) (left 120) (arc 70 60) (left 120) (right 10)))"))
  "What the demo draws with the L-systems example's functions, and the name
each picture is saved under in turtle/, for the gallery `make demo' makes.")

(defun demo-save-still (name)
  "The canvas as a picture, without the turtle, as turtle/NAME.png."
  (let ((path (demo-path (format nil "turtle/~a.png" name))))
    (ensure-directories-exist path)
    (let ((*canvas-paint-turtle* nil))
      (save-canvas-png path))))

(defun demo-watch-turtle (listener example &key (scale 5))
  "Run EXAMPLE and photograph the turtle drawing it.  WAIT is SCALE times
slower than it says, so that the photographs keep up; each frame is shown for
the time it took over SCALE, which is the drawing at its own speed."
  (setf *canvas-time-scale* scale)
  (unwind-protect
       (progn
         (run-example-in-listener listener example)
         (demo-expect (wait-for (lambda () (not (waiting-at-top-level-p listener))) :timeout 10)
                      (format nil "~a to start" example))
         (let ((last (get-internal-real-time))
               (deadline (+ (get-universal-time) 180)))
           (loop
             (pump 0.04d0)
             (let ((now (get-internal-real-time)))
               (demo-frame (/ (- now last) internal-time-units-per-second scale 1d0))
               (setf last now))
             (when (waiting-at-top-level-p listener)
               (return))
             (demo-expect (< (get-universal-time) deadline) (format nil "~a to finish" example)))))
    (setf *canvas-time-scale* 1))
  (pump-for 0.3d0)
  (demo-frame 2.0d0))

(defun demo-turtle (listener)
  "The turtle watched drawing a flower, then the L-systems, each saved for the
gallery."
  (demo-place-canvas (listener-window listener))
  (demo-caption "The turtle can be watched: it walks, fills what it walks round, and stamps")
  (demo-watch-turtle listener "turtle")
  (demo-caption "An L-system is a string rewritten again and again, then walked by the turtle")
  (let ((before (length (transcript-text listener))))
    (run-example-in-listener listener "lsystem")
    (demo-drawn-at-prompt "the dragon curve" before))
  (demo-save-still "dragon")
  (demo-frame 2.6d0)
  (dolist (entry *demo-turtle-gallery*)
    (demo-type (second entry) :per-key (if (> (length (second entry)) 30) 0.02d0 0.06d0))
    (let ((before (length (transcript-text listener))))
      (objc:invoke (demo-view) "insertNewline:" (cffi:null-pointer))
      (demo-drawn-at-prompt (first entry) before))
    (demo-save-still (first entry))
    (demo-frame 1.8d0))
  (hide-canvas)
  (pump-for 0.3d0))

(defun demo-drawn-at-prompt (what before)
  "Wait for a prompt after the transcript's first BEFORE characters -- the
form has been evaluated -- and the canvas to have been painted since."
  (let ((paints *canvas-paints*))
    (demo-expect (wait-for (lambda () (and (search "CL-USER> " (transcript-text *listener*)
                                                   :start2 before)
                                           (waiting-at-top-level-p *listener*)))
                           :timeout 60)
                 what)
    (demo-expect (wait-for (lambda () (and (canvas-visible-p) (> *canvas-paints* paints)))
                           :timeout 20)
                 (format nil "~a painted" what)))
  (pump-for 0.3d0))

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
    ;; One size everywhere, so the video is the same from any machine: big
    ;; enough for the pane and the transcript together, small enough for any
    ;; screen -- a CI runner's leaves about 680 points, and 700 was clamped to
    ;; 677 there and to 639 here.  Placed inside the visible frame, so nothing
    ;; moves it.
    (let ((visible (objc:invoke (objc:invoke window "screen") "visibleFrame")))
      (objc:invoke window "setFrame:display:"
                   (vector (+ (aref visible 0) 40d0)
                           (- (+ (aref visible 1) (aref visible 3)) 40d0 *demo-window-height*)
                           *demo-window-width* *demo-window-height*)
                   t))
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
    ;; Waited for, not just looked for.  One run in five stopped here, with
    ;; the pane up and no frame for AVERAGE in it yet; why was not found, and
    ;; waiting costs nothing when the frame is already there.
    (flet ((average-frame ()
             (let ((items (getf (pane-views listener) :backtrace-items)))
               (and items
                    (position-if (lambda (f) (search "AVERAGE" (backtrace-frame-line f)))
                                 (backtrace-items-frames items))))))
      (demo-expect (wait-for #'average-frame :timeout 10) "a frame for AVERAGE")
      (objc:invoke (objc:invoke (getf (pane-views listener) :backtrace) "documentView")
                   "expandItem:"
                   (aref (backtrace-items-roots (getf (pane-views listener) :backtrace-items))
                         (average-frame))))
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

    ;; The editor, when the image has it: src/macos/heml-demo.lisp.
    (let ((editor (find-symbol "DEMO-EDITOR" "LISP-LISTENER")))
      (when (and editor (fboundp editor))
        (funcall editor listener)))

    (demo-canvas listener)

    (demo-turtle listener)

    (demo-inspector listener)

    (demo-caption "Settings… has the switches, and ⌘+ and ⌘- change the size of the type")
    (demo-settings listener)

    (demo-caption "⌘K clears the transcript")
    (clear-transcript listener) (pump-for 0.3d0) (demo-frame 2.0d0)
    (demo-caption nil)

    (demo-write-lists)
    (note "demo: ~d frames, ~,1f seconds" *demo-count* *demo-clock*)
    (finish-and-exit 0)))
