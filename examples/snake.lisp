;;; Snake -- the arrow keys steer; on a phone, the arrows under the canvas.
;;;
;;; Eat the red squares.  Do not eat the wall, or yourself.  Escape gives up.
;;; The snake is a list of squares, head first: each turn a new head goes on
;;; the front and, unless it has just eaten, the last square comes off the back.

(defun snake ()
  (show)
  (loop while (key))                    ; forget anything pressed before now
  (let ((body (list '(10 . 10) '(9 . 10) '(8 . 10)))
        (heading '(1 . 0))
        (food '(15 . 10)))
    (flet ((square (at)
             (box (- (* 10 (car at)) 100) (- (* 10 (cdr at)) 100) 9 9)))
      (loop
        (case (key)
          (:up (setf heading '(0 . 1)))
          (:down (setf heading '(0 . -1)))
          (:left (setf heading '(-1 . 0)))
          (:right (setf heading '(1 . 0)))
          (:escape (return)))
        (let ((head (cons (+ (car (first body)) (car heading))
                          (+ (cdr (first body)) (cdr heading)))))
          (unless (and (<= 0 (car head) 19)
                       (<= 0 (cdr head) 19)
                       (not (member head body :test #'equal)))
            (return))
          (push head body)
          (if (equal head food)
              (setf food (cons (random 20) (random 20)))
              (setf body (butlast body))))
        (frame
          (color :gray)
          (rect -100 -100 200 200)
          (color :red)
          (square food)
          (color :green)
          (mapc #'square body))
        (wait 0.15)))
    (color :white)
    (text -52 0 (format nil "Game over: ~d" (- (length body) 3)) 12)
    (- (length body) 3)))

(snake)
