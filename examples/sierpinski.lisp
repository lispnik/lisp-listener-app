;;; Sierpinski -- pick a corner at random, go half way to it, make a mark.
;;;
;;; Three corners, a coin with three sides, and no plan at all: the triangle
;;; with the holes in it turns up anyway.  Try (sierpinski 8000).

(defun sierpinski (&optional (marks 3000))
  (let ((corners '((-92 . -80) (92 . -80) (0 . 80)))
        (x 0.0)
        (y 0.0))
    (frame
      (color :cyan)
      (dotimes (i marks)
        (let ((corner (nth (random 3) corners)))
          (setf x (/ (+ x (car corner)) 2)
                y (/ (+ y (cdr corner)) 2))
          (box x y 1 1))))))

(sierpinski)
