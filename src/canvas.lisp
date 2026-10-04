;;;; src/canvas.lisp -- a canvas to draw on from the prompt.
;;;;
;;;; (circle 0 0 50) at the prompt and a circle appears in a second window (a
;;;; sheet, on a phone).  That is the whole idea: a place where a form has a
;;;; picture for a value, so that a spiral, a rose curve or a game of snake is
;;;; a dozen lines typed into a listener.
;;;;
;;;; The split is the listener's own.  Drawing happens on the LISTENER thread
;;;; and touches only Lisp: each shape is a list pushed onto a display list
;;;; under a lock.  Thread 1 owns the view, and its -drawRect: paints whatever
;;;; the list holds when it is asked.  They meet at one coalesced hop, exactly
;;;; like the output stream's SCHEDULE-FLUSH -- and like it, the hop declines
;;;; while *MAIN-THREAD-TARGET* is NIL, so `make test' draws into the list and
;;;; reads it back with no window anywhere.
;;;;
;;;; The canvas is 200 units across and 200 up, from -100 to 100, with (0, 0) in
;;;; the middle and y going UP, as in mathematics.  It is scaled to fit whatever
;;;; the view turns out to be, so a drawing is the same drawing on a phone.
;;;;
;;;; The names a person types are the CANVAS package's (see package.lisp); they
;;;; are defined here, from inside LISP-LISTENER, so the two never collide.
;;;;
;;;; The painter is here too, not in the front ends: NSBezierPath and
;;;; UIBezierPath, NSColor and UIColor, differ in three selector names, and
;;;; CANVAS-TOOLKIT says which is in force.  What the front ends supply is the
;;;; view, the window or sheet around it, and the keys.

(in-package #:lisp-listener)

;;; The display list -------------------------------------------------------------

(defvar *canvas-lock* (bt:make-lock "lisp-listener canvas"))

(defvar *canvas-ops* '()
  "What is on the canvas, newest first.  Each is a list:
    (:line  COLOR WIDTH X1 Y1 X2 Y2)
    (:oval  COLOR WIDTH FILL X Y W H)
    (:rect  COLOR WIDTH FILL X Y W H)
    (:text  COLOR SIZE X Y STRING)
in canvas units, every number a double.  Under *CANVAS-LOCK*.")

(defvar *canvas-op-count* 0
  "The length of *CANVAS-OPS*, kept beside it.  Under *CANVAS-LOCK*.")

(defparameter *canvas-limit* 20000
  "How many shapes the canvas will hold.  A loop that draws for ever would
otherwise take the image's memory and thread 1's time with it; past this the
next shape is an error, which says what to do.")

(defvar *canvas-frame* nil
  "While FRAME's body runs, on the thread running it: a cons whose car collects
that frame's shapes, newest first.  NIL otherwise.")

(defparameter *canvas-default-background* '(0.07d0 0.08d0 0.11d0 1d0))

(defvar *canvas-background* *canvas-default-background*)

(defvar *canvas-keys* '()
  "Keys pressed in the canvas and not yet read, oldest first.  Under the lock.")

(defvar *canvas-redisplay-scheduled* nil
  "True between asking thread 1 to repaint and its getting round to it.")

(defvar *canvas-paints* 0
  "How many times the canvas has been painted.  For the drivers, which need to
know that -drawRect: really ran.")

(defvar *canvas-frames* 0
  "How many whole pictures FRAME has swapped in.  For the demo, which
photographs an animation a frame at a time and has to know when there is a new
one.")

(defparameter *canvas-time-scale* 1
  "What WAIT multiplies its seconds by.  `make test' sets it to 0, so that an
animation runs to its end at once, and the demo sets it to 3, so that each
frame of a game stays up long enough to be photographed.")

;;; The pen and the turtle.  Written only by whoever is drawing.

(defvar *canvas-color* '(1d0 1d0 1d0 1d0))
(defvar *canvas-pen* 1d0)
(defvar *turtle-x* 0d0)
(defvar *turtle-y* 0d0)
(defvar *turtle-heading* 0d0
  "Degrees clockwise from straight up, as in Logo.")
(defvar *turtle-down* t)

(defvar *canvas-dismissed* nil
  "True from the person closing the canvas until the next form is evaluated.

Drawing shows the canvas, which is right for the next thing typed and wrong for
the animation still running: closed in the middle of sixty frames of Life, it
came straight back with the sixty-first.  So a canvas put away stays away for
the rest of that evaluation, and what is drawn meanwhile is kept.")

(defun canvas-closed-by-person ()
  "The person closed the canvas.  Thread 1.  It is Escape to whatever reads its
keys, so that a game does not play on unseen, and it stays shut until the next
form."
  (setf *canvas-dismissed* t)
  (canvas-push-key :escape))

(defun canvas-evaluation-begins ()
  "A form is about to be evaluated: the canvas may come up again."
  (setf *canvas-dismissed* nil))

(defun real-number (value)
  "VALUE as a double.  Anything that is not a real number is a TYPE-ERROR here,
where the shape was asked for, rather than later in -drawRect:."
  (check-type value real)
  (float value 1d0))

(defun request-canvas-redisplay ()
  "Ask thread 1 to repaint, once however many shapes arrive meanwhile."
  (when (and *main-thread-target* (not *canvas-dismissed*))
    (let ((schedule nil))
      (bt:with-lock-held (*canvas-lock*)
        (unless *canvas-redisplay-scheduled*
          (setf *canvas-redisplay-scheduled* t
                schedule t)))
      (when schedule
        (on-main-thread ()
          ;; Cleared FIRST: a shape that arrives while this paints must be able
          ;; to ask again, and a hop that failed must not wedge the next.
          (bt:with-lock-held (*canvas-lock*)
            (setf *canvas-redisplay-scheduled* nil))
          ;; Asked again HERE, on thread 1, where the canvas is closed: a hop
          ;; already on its way when the person closed it would otherwise
          ;; arrive a moment later and open it again.
          (unless *canvas-dismissed*
            (redisplay-canvas))))))
  nil)

(defun canvas-add (op)
  (cond (*canvas-frame* (push op (car *canvas-frame*)))
        (t
         (bt:with-lock-held (*canvas-lock*)
           (when (>= *canvas-op-count* *canvas-limit*)
             (error "The canvas is full: it holds ~d shapes.  (clear) empties it, ~
and (frame ...) draws a picture that replaces the last one."
                    *canvas-op-count*))
           (push op *canvas-ops*)
           (incf *canvas-op-count*))
         (request-canvas-redisplay)))
  (values))

(defun canvas-contents ()
  "The display list, oldest first.  A fresh list; any thread."
  (bt:with-lock-held (*canvas-lock*)
    (reverse *canvas-ops*)))

(defun call-with-canvas-frame (function)
  (let ((*canvas-frame* (list '())))
    (funcall function)
    (let ((ops (car *canvas-frame*)))
      (bt:with-lock-held (*canvas-lock*)
        (setf *canvas-ops* ops
              *canvas-op-count* (length ops))
        (incf *canvas-frames*))))
  (request-canvas-redisplay)
  (values))

(defmacro canvas:frame (&body body)
  "Draw BODY as one picture, replacing whatever was on the canvas.

Nothing is shown until BODY has finished, so the canvas goes from one whole
picture to the next: this is how to animate.

    (dotimes (i 100)
      (frame (dot (- i 50) 0 5))
      (wait 0.02))"
  `(call-with-canvas-frame (lambda () ,@body)))

;;; The canvas ---------------------------------------------------------------------

(defun canvas:clear ()
  "Wipe the canvas, and put the turtle back in the middle, facing up."
  (setf *turtle-x* 0d0 *turtle-y* 0d0 *turtle-heading* 0d0 *turtle-down* t)
  (cond (*canvas-frame* (setf (car *canvas-frame*) '()))
        (t (bt:with-lock-held (*canvas-lock*)
             (setf *canvas-ops* '() *canvas-op-count* 0))
           (request-canvas-redisplay)))
  (values))

(defun canvas:show ()
  "Bring the canvas to the front and give it the keyboard, for a game."
  (setf *canvas-dismissed* nil)
  (when *main-thread-target*
    (on-main-thread () (show-canvas :keyboard t)))
  (values))

(defun canvas:hide ()
  "Put the canvas away.  What is drawn on it is kept."
  (when *main-thread-target*
    (on-main-thread () (hide-canvas)))
  (values))

;;; Colour ---------------------------------------------------------------------------

(defparameter *canvas-colors*
  '((:white 1 1 1) (:black 0 0 0) (:gray 0.55 0.57 0.6) (:grey 0.55 0.57 0.6)
    (:red 1 0.27 0.23) (:orange 1 0.62 0.04) (:yellow 1 0.84 0.04)
    (:green 0.2 0.84 0.3) (:cyan 0.39 0.82 1) (:blue 0.04 0.52 1)
    (:purple 0.75 0.35 0.95) (:pink 1 0.45 0.65) (:brown 0.67 0.53 0.37)))

(defun canvas-color (red &optional green blue (alpha 1))
  "A colour, as a list of four doubles, from a name or from components."
  (flet ((unit (value) (max 0d0 (min 1d0 (real-number value)))))
    (cond ((and (symbolp red) (null green))
           (let ((entry (assoc red *canvas-colors* :test #'string-equal)))
             (unless entry
               (error "There is no colour called ~s.  There are: ~{~(~a~)~^, ~}."
                      red (remove :grey (mapcar #'first *canvas-colors*))))
             (append (mapcar #'unit (rest entry)) (list 1d0))))
          ((and green blue)
           (list (unit red) (unit green) (unit blue) (unit alpha)))
          (t (error "A colour is a name, like :red, or three numbers from 0 to 1: ~
red, green and blue.")))))

(defun canvas:color (red &optional green blue (alpha 1))
  "Draw in this colour from now on: (color :red), or (color 1 0.5 0) -- red,
green and blue, each from 0 to 1."
  (setf *canvas-color* (canvas-color red green blue alpha))
  (values))

(defun hue-color (hue saturation value)
  (let* ((h (* 6 (mod (real-number hue) 1d0)))
         (s (max 0d0 (min 1d0 (real-number saturation))))
         (v (max 0d0 (min 1d0 (real-number value))))
         (sector (floor h))
         (f (- h sector))
         (p (* v (- 1 s)))
         (q (* v (- 1 (* s f))))
         (u (* v (- 1 (* s (- 1 f))))))
    (append (ecase (mod sector 6)
              (0 (list v u p)) (1 (list q v p)) (2 (list p v u))
              (3 (list p q v)) (4 (list u p v)) (5 (list v p q)))
            (list 1d0))))

(defun canvas:hue (hue &optional (saturation 1) (value 1))
  "Draw in a colour of the rainbow: 0 is red, 1/3 green, 2/3 blue, and 1 is red
again -- so (hue (/ i 100)) inside a loop walks round it."
  (setf *canvas-color* (hue-color hue saturation value))
  (values))

(defun canvas:pen (width)
  "Draw lines this thick from now on."
  (setf *canvas-pen* (max 0d0 (real-number width)))
  (values))

(defun canvas:background (red &optional green blue)
  "Colour the canvas itself: (background :black), or three numbers."
  (setf *canvas-background* (canvas-color red green blue))
  ;; Inside a frame -- or an inspector's drawing, which is one -- the colour is
  ;; that picture's, and there is no canvas to repaint for it.
  (unless *canvas-frame*
    (request-canvas-redisplay))
  (values))

;;; Shapes ---------------------------------------------------------------------------

(defun canvas:line (x1 y1 x2 y2)
  "A line from (X1, Y1) to (X2, Y2)."
  (canvas-add (list :line *canvas-color* *canvas-pen*
                    (real-number x1) (real-number y1)
                    (real-number x2) (real-number y2))))

(defun canvas-oval (x y radius fill)
  (let ((x (real-number x)) (y (real-number y)) (r (abs (real-number radius))))
    (canvas-add (list :oval *canvas-color* *canvas-pen* fill
                      (- x r) (- y r) (* 2 r) (* 2 r)))))

(defun canvas:circle (x y radius)
  "The outline of a circle centred on (X, Y)."
  (canvas-oval x y radius nil))

(defun canvas:dot (x y &optional (radius 2))
  "A filled circle centred on (X, Y)."
  (canvas-oval x y radius t))

(defun canvas-rectangle (x y width height fill)
  (canvas-add (list :rect *canvas-color* *canvas-pen* fill
                    (real-number x) (real-number y)
                    (real-number width) (real-number height))))

(defun canvas:rect (x y width height)
  "The outline of a rectangle whose bottom left corner is (X, Y)."
  (canvas-rectangle x y width height nil))

(defun canvas:box (x y width height)
  "A filled rectangle whose bottom left corner is (X, Y)."
  (canvas-rectangle x y width height t))

(defun canvas:text (x y thing &optional (size 8))
  "Write THING -- a string, a number, anything -- with its bottom left corner at
(X, Y), SIZE units tall."
  (canvas-add (list :text *canvas-color* (real-number size)
                    (real-number x) (real-number y)
                    (if (stringp thing) thing (princ-to-string thing)))))

(defparameter *canvas-far* 1d4
  "A point further out than this is not joined to its neighbours.  It is fifty
canvases off the page, where (/ 1 x) goes on its way through zero, and a line
out to it would only be a stroke down the picture.")

(defun canvas-join (points)
  "Lines through POINTS, each (x . y) or NIL where the curve has a gap."
  (loop for (a b) on points
        when (and a b)
          do (canvas:line (car a) (cdr a) (car b) (cdr b)))
  (values))

(defun canvas-point (x y)
  "The point (X . Y), or NIL when either is not a real number within reach --
(sqrt -1), say, or (/ 1 x) close to zero."
  (and (realp x) (realp y)
       (let ((x (real-number x)) (y (real-number y)))
         (and (< (abs x) *canvas-far*) (< (abs y) *canvas-far*)
              (cons x y)))))

(defun canvas:plot (function &key (from -100) (to 100) (steps 200))
  "The graph of FUNCTION: y = (FUNCTION x), for x from FROM to TO.

    (plot (lambda (x) (* 50 (sin (/ x 10)))))"
  (let ((from (real-number from)) (to (real-number to)))
    (canvas-join
     (loop for i from 0 to steps
           for x = (+ from (* (- to from) (/ i steps)))
           collect (canvas-point x (funcall function x))))))

(defun canvas:curve (function &key (from 0) (to 1) (steps 200))
  "A curve through the points FUNCTION returns: it is called with a number
going from FROM to TO, and answers two values, x and y.

    (curve (lambda (a) (values (* 80 (cos a)) (* 80 (sin (* 2 a)))))
           :to (* 2 pi))"
  (let ((from (real-number from)) (to (real-number to)))
    (canvas-join
     (loop for i from 0 to steps
           for parameter = (+ from (* (- to from) (/ i steps)))
           collect (multiple-value-bind (x y) (funcall function parameter)
                     (canvas-point x y))))))

;;; The turtle -----------------------------------------------------------------------

(defun canvas:forward (distance)
  "Walk the turtle DISTANCE the way it is facing, drawing if its pen is down."
  (let* ((distance (real-number distance))
         (angle (* *turtle-heading* (/ pi 180)))
         (x (+ *turtle-x* (* distance (sin angle))))
         (y (+ *turtle-y* (* distance (cos angle)))))
    (when *turtle-down*
      (canvas:line *turtle-x* *turtle-y* x y))
    (setf *turtle-x* x *turtle-y* y)
    (values)))

(defun canvas:back (distance)
  "Walk the turtle backwards, without turning it round."
  (canvas:forward (- (real-number distance))))

(defun canvas:right (degrees)
  "Turn the turtle clockwise."
  (setf *turtle-heading* (mod (+ *turtle-heading* (real-number degrees)) 360d0))
  (values))

(defun canvas:left (degrees)
  "Turn the turtle anticlockwise."
  (canvas:right (- (real-number degrees))))

(defun canvas:pen-up ()
  "Lift the turtle's pen: it moves without drawing."
  (setf *turtle-down* nil)
  (values))

(defun canvas:pen-down ()
  "Put the turtle's pen back down."
  (setf *turtle-down* t)
  (values))

(defun canvas:home ()
  "Put the turtle back in the middle, facing up, without drawing."
  (setf *turtle-x* 0d0 *turtle-y* 0d0 *turtle-heading* 0d0)
  (values))

(defun canvas:move-to (x y)
  "Put the turtle at (X, Y) without drawing, facing the way it was."
  (setf *turtle-x* (real-number x) *turtle-y* (real-number y))
  (values))

;;; Time and keys --------------------------------------------------------------------

(defun canvas:wait (seconds)
  "Do nothing for SECONDS: the pause between one frame and the next."
  (let ((seconds (* (real-number seconds) *canvas-time-scale*)))
    ;; In slices, so that Stop is never more than a moment away.
    (loop while (plusp seconds)
          do (sleep (min seconds 0.05d0))
             (decf seconds 0.05d0)))
  (values))

(defun canvas:key ()
  "The next key pressed in the canvas, or NIL when there is none waiting.

An arrow is :up, :down, :left or :right; then :space, :return and :escape; and
any other key is its character.  It never waits, so a game can ask every turn."
  (bt:with-lock-held (*canvas-lock*)
    (pop *canvas-keys*)))

(defun canvas-push-key (key)
  "Record KEY as pressed.  Any thread; the front ends call it on thread 1."
  (when key
    (bt:with-lock-held (*canvas-lock*)
      ;; Bounded: nobody may be reading, and a held key repeats.
      (when (< (length *canvas-keys*) 64)
        (setf *canvas-keys* (append *canvas-keys* (list key))))))
  key)

;;; The pointer ----------------------------------------------------------------------
;;;
;;; A mouse on the Mac, a finger on a phone.  The front end reports where it is
;;; in the view's own coordinates; here that becomes canvas units, and a press
;;; is also a key, :CLICK, so that a game which reads keys hears a tap.

(defvar *canvas-pointer* (list 0d0 0d0 nil)
  "Where the pointer last was, in canvas units, and whether it is down.
Under *CANVAS-LOCK*.")

(defun canvas:pointer ()
  "Where the mouse or the finger is on the canvas, and whether it is down:
three values, x, y, and true while the button is held or the finger is on.
A mouse is followed whether its button is down or not; a finger only while it
touches.

    (dotimes (i 500)                      ; draw with it, for ten seconds
      (multiple-value-bind (x y down) (pointer)
        (when down (dot x y 1)))
      (wait 0.02))

A press is also a key: (key) answers :click for it."
  (bt:with-lock-held (*canvas-lock*)
    (values-list *canvas-pointer*)))

(defun canvas-point-from-view (x y width height)
  "The canvas's (x . y) for a point in a view WIDTH by HEIGHT whose y runs
down: CANVAS-DEVICE-OPS, backwards."
  (let ((scale (/ (max 1d0 (min width height)) 200d0)))
    (cons (/ (- x (/ width 2d0)) scale)
          (/ (- (/ height 2d0) y) scale))))

(defun canvas-pointer-event (phase x y width height)
  "The pointer went :DOWN, did a :MOVE, or came :UP at (X, Y) in a view WIDTH
by HEIGHT.  Thread 1; what both front ends call."
  (let ((point (canvas-point-from-view x y width height)))
    (bt:with-lock-held (*canvas-lock*)
      (setf *canvas-pointer*
            (list (car point) (cdr point)
                  (ecase phase
                    (:down t)
                    (:move (third *canvas-pointer*))
                    (:up nil))))))
  (when (eq phase :down)
    (canvas-push-key :click))
  phase)

(defun canvas-key-for-character (character)
  "What KEY answers for a character from a keyboard event: a keyword for the
keys that have no character worth the name, and the character otherwise."
  (case (char-code character)
    (#xF700 :up) (#xF701 :down) (#xF702 :left) (#xF703 :right) ; NSUpArrowFunctionKey...
    (32 :space)
    ((13 3) :return)
    (27 :escape)
    (t character)))

(defun live-pointer-p (pointer)
  "True of a foreign pointer that is not null."
  (and pointer (cffi:pointerp pointer) (not (cffi:null-pointer-p pointer))))

;;; Painting -------------------------------------------------------------------------
;;;
;;; From here on, thread 1.

(defun canvas-device-ops (width height &optional (contents (canvas-contents))
                                                 (canvas-background *canvas-background*))
  "What to paint in a view WIDTH by HEIGHT whose y runs DOWN -- both views are
flipped, so that one painter does for both.  Answers the background and a list
of operations, oldest first, in the view's own coordinates:

    (:lines COLOR WIDTH x1 y1 x2 y2 ...)       one path, many segments
    (:rects COLOR WIDTH FILL x y w h ...)      one path, many rectangles
    (:oval  COLOR WIDTH FILL x y w h)
    (:text  COLOR SIZE x y STRING)             x, y the TOP left corner

Neighbouring lines of one colour and width are gathered into one operation, and
rectangles likewise.  A send to Objective-C is the cost here, a turtle's walk is
several hundred lines, and one path stroked once is a fifth of the sends.

CONTENTS is the display list, oldest first, and CANVAS-BACKGROUND the colour
behind it: the canvas's own unless given, which is how an inspector's drawing
-- a list of the same shapes -- is painted by the same code."
  (let* ((scale (/ (min width height) 200d0))
         (cx (/ width 2d0))
         (cy (/ height 2d0))
         (result '())
         (run nil))
    (labels ((dx (x) (+ cx (* x scale)))
             (dy (y) (- cy (* y scale)))
             (flush ()
               (when run
                 (destructuring-bind (kind key . numbers) run
                   (push (append (list kind) key (reverse numbers)) result))
                 (setf run nil)))
             ;; NUMBERS are pushed in reverse, so they go in back to front.
             (extend (kind key &rest numbers)
               (unless (and run (eq (first run) kind) (equal (second run) key))
                 (flush)
                 (setf run (list kind key)))
               (dolist (number numbers)
                 (push number (cddr run)))))
      (dolist (op contents)
        (ecase (first op)
          (:line
           (destructuring-bind (color pen x1 y1 x2 y2) (rest op)
             (extend :lines (list color (* pen scale))
                     (dx x1) (dy y1) (dx x2) (dy y2))))
          (:rect
           (destructuring-bind (color pen fill x y w h) (rest op)
             ;; The corner given is the bottom left; flipped, the top left is
             ;; the one HEIGHT further up.
             (if fill
                 ;; A filled one has its EDGES put on whole points, and its
                 ;; size taken from them: two boxes that meet on the canvas
                 ;; then meet on the screen.  Scaled and left where they fell,
                 ;; each edge was antialiased on its own, and a grid of boxes
                 ;; -- the Mandelbrot set -- had a hairline between every row.
                 (let ((left (fround (dx x))) (right (fround (dx (+ x w))))
                       (top (fround (dy (+ y h)))) (bottom (fround (dy y))))
                   (extend :rects (list color (* pen scale) fill)
                           left top (- right left) (- bottom top)))
                 (extend :rects (list color (* pen scale) fill)
                         (dx x) (dy (+ y h)) (* w scale) (* h scale)))))
          (:oval
           (flush)
           (destructuring-bind (color pen fill x y w h) (rest op)
             (push (list :oval color (* pen scale) fill
                         (dx x) (dy (+ y h)) (* w scale) (* h scale))
                   result)))
          (:text
           (flush)
           (destructuring-bind (color size x y string) (rest op)
             (let ((points (* size scale)))
               ;; A line of type is about a fifth taller than its size.
               (push (list :text color points (dx x) (- (dy y) (* 1.2d0 points)) string)
                     result))))))
      (flush))
    (values canvas-background (nreverse result))))

(defun canvas-class (name)
  "NSColor or UIColor, NSBezierPath or UIBezierPath."
  (concatenate 'string (ecase (canvas-toolkit) (:appkit "NS") (:uikit "UI")) name))

(defun set-canvas-color (color)
  (destructuring-bind (red green blue alpha) color
    (objc:invoke (objc:invoke (canvas-class "Color") "colorWithRed:green:blue:alpha:"
                              red green blue alpha)
                 "set")))

(defun make-canvas-path (width)
  (let ((path (objc:invoke (canvas-class "BezierPath") "bezierPath")))
    (objc:invoke path "setLineWidth:" (max width 0.5d0))
    (objc:invoke path "setLineCapStyle:" 1)     ; round, on both
    (objc:invoke path "setLineJoinStyle:" 1)
    path))

(defun paint-canvas-op (op)
  (let ((appkit (eq (canvas-toolkit) :appkit)))
    (ecase (first op)
      (:lines
       (destructuring-bind (color width . numbers) (rest op)
         (set-canvas-color color)
         (let ((path (make-canvas-path width))
               (pen-x nil) (pen-y nil))
           (loop for (x1 y1 x2 y2) on numbers by #'cddddr
                 do ;; A segment that starts where the last one ended needs
                    ;; no move, and joins it properly.
                    (unless (and pen-x (= pen-x x1) (= pen-y y1))
                      (objc:invoke path "moveToPoint:" (vector x1 y1)))
                    (objc:invoke path (if appkit "lineToPoint:" "addLineToPoint:")
                                 (vector x2 y2))
                    (setf pen-x x2 pen-y y2))
           (objc:invoke path "stroke"))))
      (:rects
       (destructuring-bind (color width fill . numbers) (rest op)
         (set-canvas-color color)
         (let ((path (make-canvas-path width)))
           (loop for (x y w h) on numbers by #'cddddr
                 for rectangle = (vector x y w h)
                 do (if appkit
                        (objc:invoke path "appendBezierPathWithRect:" rectangle)
                        (objc:invoke path "appendPath:"
                                     (objc:invoke "UIBezierPath" "bezierPathWithRect:"
                                                  rectangle))))
           (objc:invoke path (if fill "fill" "stroke")))))
      (:oval
       (destructuring-bind (color width fill x y w h) (rest op)
         (set-canvas-color color)
         (let ((path (objc:invoke (canvas-class "BezierPath") "bezierPathWithOvalInRect:"
                                  (vector x y w h))))
           (objc:invoke path "setLineWidth:" (max width 0.5d0))
           (objc:invoke path (if fill "fill" "stroke")))))
      (:text
       (destructuring-bind (color size x y string) (rest op)
         (destructuring-bind (red green blue alpha) color
           (let ((attributes (objc:invoke "NSMutableDictionary" "dictionary"))
                 (ns-string (objc:string-to-ns-string string t)))
             (objc:invoke attributes "setObject:forKey:"
                          (transcript-font (max size 1d0))
                          (%ns-string-constant "NSFontAttributeName"))
             (objc:invoke attributes "setObject:forKey:"
                          (objc:invoke (canvas-class "Color")
                                       "colorWithRed:green:blue:alpha:"
                                       red green blue alpha)
                          (%ns-string-constant "NSForegroundColorAttributeName"))
             (objc:invoke ns-string "drawAtPoint:withAttributes:"
                          (vector x y) attributes))))))))

(defun paint-shapes (contents background width height)
  "Paint CONTENTS, a display list, over BACKGROUND into the current graphics
context, in a view WIDTH by HEIGHT.  One bad shape is reported and the rest
are still drawn."
  (multiple-value-bind (background ops)
      (canvas-device-ops width height contents background)
    (set-canvas-color background)
    (objc:invoke (objc:invoke (canvas-class "BezierPath") "bezierPathWithRect:"
                              (vector 0d0 0d0 (real-number width) (real-number height)))
                 "fill")
    (dolist (op ops)
      (handler-case (paint-canvas-op op)
        (error (condition) (note "canvas: ~a" condition)))))
  (values))

(defun paint-canvas (width height)
  "Paint the canvas into the current graphics context: what both views'
-drawRect: do."
  (paint-shapes (canvas-contents) *canvas-background* width height)
  (incf *canvas-paints*)
  (values))

;;; Saving ---------------------------------------------------------------------------
;;;
;;; (save "name.png") is the canvas as the view paints it, which is the front
;;; end's to do; (save "name.svg") is the display list written out as SVG, which
;;; is all here, the same on both, and what `make test' can check.

(defun canvas-save-path (name)
  "Where NAME goes: itself if it says where, and otherwise among the person's
own files -- ~/Pictures on the Mac, the app's folder on a phone.  .png when it
names no type."
  (let* ((path (pathname name))
         (path (if (pathname-type path) path (make-pathname :type "png" :defaults path))))
    (merge-pathnames path (or (ignore-errors (documents-directory))
                              *default-pathname-defaults*))))

(defun svg-color (color)
  (destructuring-bind (red green blue alpha) color
    (format nil "rgb(~d,~d,~d)~:[~;\" opacity=\"~,2f~]"
            (round (* 255 red)) (round (* 255 green)) (round (* 255 blue))
            (< alpha 1) alpha)))

(defun svg-escape (string)
  (with-output-to-string (out)
    (loop for character across string
          do (case character
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (#\& (write-string "&amp;" out))
               (t (write-char character out))))))

(defun write-canvas-svg (stream)
  "The canvas as an SVG document.  Its y runs down, so every y is turned over;
otherwise the numbers are the canvas's own."
  (let ((*read-default-float-format* 'double-float))
    (flet ((up (y)
             ;; From zero, not negated: -0.0 prints as "-0.00".
             (- 0d0 y))
           (paint (color width fill)
             (if fill
                 (format nil "fill=\"~a\"" (svg-color color))
                 (format nil "fill=\"none\" stroke=\"~a\" stroke-width=\"~,2f\""
                         (svg-color color) width))))
      (format stream "<svg xmlns=\"http://www.w3.org/2000/svg\" ~
viewBox=\"-100 -100 200 200\" width=\"800\" height=\"800\">~%")
      (format stream "<rect x=\"-100\" y=\"-100\" width=\"200\" height=\"200\" fill=\"~a\"/>~%"
              (svg-color *canvas-background*))
      (dolist (op (canvas-contents))
        (ecase (first op)
          (:line
           (destructuring-bind (color pen x1 y1 x2 y2) (rest op)
             (format stream "<line x1=\"~,2f\" y1=\"~,2f\" x2=\"~,2f\" y2=\"~,2f\" ~
stroke=\"~a\" stroke-width=\"~,2f\" stroke-linecap=\"round\"/>~%"
                     x1 (up y1) x2 (up y2) (svg-color color) pen)))
          (:oval
           (destructuring-bind (color pen fill x y w h) (rest op)
             (format stream "<ellipse cx=\"~,2f\" cy=\"~,2f\" rx=\"~,2f\" ry=\"~,2f\" ~a/>~%"
                     (+ x (/ w 2)) (up (+ y (/ h 2))) (/ w 2) (/ h 2) (paint color pen fill))))
          (:rect
           (destructuring-bind (color pen fill x y w h) (rest op)
             (format stream "<rect x=\"~,2f\" y=\"~,2f\" width=\"~,2f\" height=\"~,2f\" ~a/>~%"
                     x (up (+ y h)) w h (paint color pen fill))))
          (:text
           (destructuring-bind (color size x y string) (rest op)
             (format stream "<text x=\"~,2f\" y=\"~,2f\" font-size=\"~,2f\" ~
font-family=\"Menlo, monospace\" fill=\"~a\">~a</text>~%"
                     x (up y) size (svg-color color) (svg-escape string))))))
      (format stream "</svg>~%")))
  (values))

(defun canvas:save (name)
  "Save the canvas as a picture, and answer where it went.

\"name.png\" is the canvas as it looks; \"name.svg\" is the drawing itself,
which stays sharp at any size.  A name with no directory goes among your own
files: ~/Pictures on the Mac, the app's folder in Files on a phone."
  (let ((path (canvas-save-path name)))
    (ensure-directories-exist path)
    (cond ((string-equal (pathname-type path) "svg")
           (with-open-file (out path :direction :output :if-exists :supersede
                                     :external-format :utf-8)
             (write-canvas-svg out)))
          ((not (string-equal (pathname-type path) "png"))
           (error "The canvas can be saved as .png or .svg, not .~a." (pathname-type path)))
          ((null *main-thread-target*)
           (error "There is no window to take a picture of.  (save \"name.svg\") needs none."))
          (t
           ;; Waited for: the file should be there when this returns.
           (on-main-thread (:wait t) (save-canvas-png (namestring path)))))
    (truename path)))

;;; The names, in CL-USER ------------------------------------------------------------

(defun install-user-vocabulary (&optional (package (find-package "COMMON-LISP-USER")))
  "Make the canvas's names, and EXAMPLE and EXAMPLES, plain symbols in PACKAGE,
so that (forward 50) at the prompt means the turtle.  Answers the names it had
to leave alone, which is none in an image that has not used them for something
else.

IMPORT and not USE-PACKAGE, one symbol at a time: a name the person already
gave a meaning to is theirs, and they can still write CANVAS:LINE.  A symbol
the reader merely interned -- typed once, never defined -- is replaced."
  (let ((skipped '()))
    (flet ((bring (symbol)
             (multiple-value-bind (existing status)
                 (find-symbol (symbol-name symbol) package)
               (cond ((null status) (import symbol package))
                     ((eq existing symbol))
                     ((and (eq status :internal)
                           (eq (symbol-package existing) package)
                           (not (boundp existing))
                           (not (fboundp existing)))
                      (unintern existing package)
                      (import symbol package))
                     (t (push symbol skipped))))))
      (do-external-symbols (symbol (find-package "CANVAS"))
        (bring symbol))
      (dolist (symbol '(examples example example-source example-edit download))
        (bring symbol)))
    (when skipped
      (note "canvas: ~{~a~^, ~} already had a meaning in ~a; write CANVAS:~a there"
            (mapcar #'symbol-name skipped) (package-name package)
            (symbol-name (first skipped))))
    skipped))
