;;; Clock -- the time, for half a minute.
;;;
;;; A hand is a line from the middle, and its angle is how far round the dial
;;; it has gone.  Try (clock 300) for five minutes.  Escape stops it.

(defun hand (turn length thickness)
  (let ((angle (* 2 pi turn)))
    (pen thickness)
    (line 0 0 (* length (sin angle)) (* length (cos angle)))))

(defun clock (&optional (seconds 30))
  (dotimes (tick seconds)
    (when (eq (key) :escape)
      (return))
    (multiple-value-bind (s m h) (get-decoded-time)
      (frame
        (color :white)
        (pen 2)
        (circle 0 0 90)
        (dotimes (i 12)
          (let ((angle (* 2 pi (/ i 12))))
            (dot (* 80 (sin angle)) (* 80 (cos angle)) 2)))
        (hand (/ (+ h (/ m 60)) 12) 48 5)
        (hand (/ (+ m (/ s 60)) 60) 72 3)
        (color :red)
        (hand (/ s 60) 78 1)))
    (wait 1))
  (pen 1))

(clock)
