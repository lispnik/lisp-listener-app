;;; Mandelbrot -- z -> z² + c, over and over, for every point c.
;;;
;;; A point is in the set if z never runs away.  Each square is coloured by how
;;; long it took to; the dark ones never did.  Lisp has complex numbers, so the
;;; rule is written as it is said.  Try (mandelbrot 80).

(defun escape (c limit)
  (let ((z 0))
    (dotimes (i limit nil)
      (setf z (+ (* z z) c))
      (when (> (abs z) 2)
        (return i)))))

(defun mandelbrot (&optional (size 48) (limit 24))
  (let ((side (/ 200 size)))
    (frame
      (dotimes (row size)
        (dotimes (column size)
          (let ((steps (escape (complex (- (* 3.0 (/ column size)) 2.2)
                                        (- (* 3.0 (/ row size)) 1.5))
                               limit)))
            (when steps
              (hue (/ steps limit))
              (box (- (* column side) 100) (- (* row side) 100) side side))))))))

(mandelbrot)
