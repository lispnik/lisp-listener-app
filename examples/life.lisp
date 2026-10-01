;;; Life -- John Conway's game, on a board whose edges wrap round.
;;;
;;; A live cell with two or three live neighbours lives on; a dead one with
;;; exactly three comes to life.  That is all of it.  Try (life 400).

(defparameter *board* 25)

(defun neighbours (cells x y)
  (loop for dx from -1 to 1
        sum (loop for dy from -1 to 1
                  count (and (not (= dx dy 0))
                             (aref cells
                                   (mod (+ x dx) *board*)
                                   (mod (+ y dy) *board*))))))

(defun generation (cells)
  (let ((next (make-array (list *board* *board*) :initial-element nil)))
    (dotimes (x *board* next)
      (dotimes (y *board*)
        (let ((n (neighbours cells x y)))
          (setf (aref next x y)
                (if (aref cells x y) (<= 2 n 3) (= n 3))))))))

(defun life (&optional (generations 150))
  (let ((cells (make-array (list *board* *board*)))
        (side (/ 200 *board*)))
    (dotimes (x *board*)
      (dotimes (y *board*)
        (setf (aref cells x y) (zerop (random 3)))))
    (dotimes (i generations)
      (frame
        (hue (/ i 150))
        (dotimes (x *board*)
          (dotimes (y *board*)
            (when (aref cells x y)
              (box (- (* x side) 100) (- (* y side) 100) (- side 1) (- side 1))))))
      (setf cells (generation cells))
      (wait 0.08))))

(life)
