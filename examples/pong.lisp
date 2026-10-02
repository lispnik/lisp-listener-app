;;; Pong -- you are on the left: up and down move your bat.  First to three.
;;;
;;; The other bat follows the ball, but not quite fast enough.  Escape gives up.

(defun pong ()
  (show)
  (loop while (key))                    ; forget anything pressed before now
  (let ((you 0) (them 0)                ; how high each bat is
        (yours 0) (theirs 0)            ; the score
        (x 0) (y 0) (dx 3) (dy 2))
    (loop until (or (= yours 3) (= theirs 3))
          do (case (key)
               (:up (setf you (min 78 (+ you 14))))
               (:down (setf you (max -78 (- you 14))))
               (:escape (return)))
             (incf them (max -2.2 (min 2.2 (- y them))))
             (incf x dx)
             (incf y dy)
             (when (> (abs y) 96)
               (setf dy (- dy)))
             (cond ((and (< x -86) (< (abs (- y you)) 22))
                    (setf dx (abs dx)
                          dy (+ dy (- (random 2.0) 1))))
                   ((and (> x 86) (< (abs (- y them)) 22))
                    (setf dx (- (abs dx))))
                   ((< x -100)
                    (incf theirs)
                    (setf x 0 y 0 dx 3 dy (- (random 4.0) 2)))
                   ((> x 100)
                    (incf yours)
                    (setf x 0 y 0 dx -3 dy (- (random 4.0) 2))))
             (frame
               (color :white)
               (box -94 (- you 20) 4 40)
               (box 90 (- them 20) 4 40)
               (dot x y 3)
               (text -30 82 yours 12)
               (text 22 82 theirs 12))
             (wait 0.03))
    (color :white)
    (text -34 -6 (if (> yours theirs) "You win" "You lose") 12)
    (list yours theirs)))

(pong)
