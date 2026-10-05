;;; L-systems -- a string rewritten over and over, then walked by the turtle.
;;;
;;; F and G walk forward, + turns right, - turns left, and [ ] remember a place
;;; and go back to it.  Try (snowflake 4), (hilbert 5), (arrowhead 7), (plant 5),
;;; or rules of your own: (l-system "F" '((#\F . "F+F-F-F+F")) 4 90)

(defun rewrite (axiom rules n)
  "AXIOM with every character that has a rule replaced, N times over."
  (if (zerop n)
      axiom
      (rewrite (with-output-to-string (out)
                 (loop for c across axiom
                       do (write-string (or (cdr (assoc c rules)) (string c)) out)))
               rules (1- n))))

(defun walk (path step angle &key (draw t) (hues '(0 1)))
  "Walk PATH, coloured from one hue to the other on the way.  Answers the box
it covered: left, bottom, right, top."
  (let ((stack '()) (box (multiple-value-call #'list (pos) (pos)))
        (steps (max 1 (count-if (lambda (c) (find c "FG")) path))) (done 0))
    (if draw (pen-down) (pen-up))
    (loop for c across path
          do (case c
               ((#\F #\G)
                ;; In forty bands, so that the canvas paints a band as one path.
                (hue (+ (first hues) (* (- (second hues) (first hues))
                                        (/ (floor (* 40 (incf done)) steps) 40))))
                (forward step)
                (multiple-value-bind (x y) (pos)
                  (setf box (list (min x (first box)) (min y (second box))
                                  (max x (third box)) (max y (fourth box))))))
               (#\+ (right angle))
               (#\- (left angle))
               (#\[ (push (list (multiple-value-list (pos)) (heading)) stack))
               (#\] (destructuring-bind ((x y) h) (pop stack)
                      (pen-up) (go-to x y) (set-heading h) (when draw (pen-down))))))
    (values-list box)))

(defun l-system (axiom rules n angle &key (heading 0) (hues '(0 1)) fill)
  "Rewrite AXIOM N times by RULES, then walk it, sized to fill the canvas --
and if FILL is a colour, (r g b a), fill what it walks round with it."
  (let ((path (rewrite axiom rules n))
        (speed (turtle-speed 0)))
    ;; Once with the pen up and a step of 1, to see how big it comes out.
    (clear) (set-heading heading)
    (multiple-value-bind (left bottom right top) (walk path 1 angle :draw nil)
      (turtle-speed speed)
      (let ((step (/ 180 (max (- right left) (- top bottom) 1))))
        (clear)
        (move-to (* step (/ (+ left right) -2)) (* step (/ (+ bottom top) -2)))
        (set-heading heading)
        (if fill
            (filled (walk path step angle :hues hues) (apply #'color fill))
            (walk path step angle :hues hues))))
    (values)))

(defun snowflake (&optional (n 4))
  (background :black)
  (l-system "F--F--F" '((#\F . "F+F--F+F")) n 60 :heading 90 :hues '(0.5 0.7)
            :fill '(0.2 0.5 1 0.3)))

(defun dragon (&optional (n 12))
  (background :black)
  (l-system "FX" '((#\X . "X+YF+") (#\Y . "-FX-Y")) n 90))

(defun hilbert (&optional (n 5))
  (background :black)
  (l-system "A" '((#\A . "+BF-AFA-FB+") (#\B . "-AF+BFB+FA-")) n 90 :hues '(0.55 1.15)))

(defun arrowhead (&optional (n 7))
  (background :black)
  (l-system "F" '((#\F . "G-F-G") (#\G . "F+G+F")) n 60 :heading 90 :hues '(0.8 1.1)))

(defun plant (&optional (n 5))
  (background :black)
  (l-system "X" '((#\X . "F+[[X]-X]-F[-X]+X") (#\F . "FF")) n 25 :heading -20
            :hues '(0.1 0.4)))

(dragon)
