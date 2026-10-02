;;; Ball -- gravity, a floor, and a little lost at every bounce.
;;;
;;; Each frame the speed changes by gravity and the place changes by the speed.
;;; That is all there is to it.  Try (ball 12).  Escape stops it.

(defun ball (&optional (balls 4))
  (let ((all (loop repeat balls
                   collect (vector (- (random 160.0) 80)      ; x
                                   (random 80.0)              ; y
                                   (- (random 6.0) 3)         ; speed across
                                   0.0                        ; speed up
                                   (random 1.0)))))           ; colour
    (dotimes (tick 300)
      (when (eq (key) :escape)
        (return))
      (frame
        (color :gray)
        (rect -100 -100 200 200)
        (dolist (b all)
          (decf (aref b 3) 0.4)
          (incf (aref b 0) (aref b 2))
          (incf (aref b 1) (aref b 3))
          (when (< (aref b 1) -92)
            (setf (aref b 1) -92
                  (aref b 3) (* -0.9 (aref b 3))))
          (when (> (abs (aref b 0)) 92)
            (setf (aref b 0) (max -92 (min 92 (aref b 0)))
                  (aref b 2) (- (aref b 2))))
          (hue (aref b 4))
          (dot (aref b 0) (aref b 1) 8)))
      (wait 0.03))))

(ball)
