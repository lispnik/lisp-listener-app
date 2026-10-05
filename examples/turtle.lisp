;;; Turtle -- a turtle you can watch, which fills what it walks round and stamps.
;;;
;;; (turtle-speed 1) is slow enough to follow, and 0 draws at once.  Try
;;; (flower 12 :purple), or (flower 5 :orange).

(defun petal (size)
  "Two arcs back to back, filled.  The turtle ends where it began, facing the
way it did, so petals can go round in a ring."
  (filled
    (arc size 60)
    (left 120)
    (arc size 60)
    (left 120)))

(defun flower (&optional (petals 8) (shade :pink))
  (clear)
  (background :black)
  (let ((speed (turtle-speed 8)))
    (unwind-protect
         (progn
           ;; A stem, and a leaf on it.
           (color :green)
           (pen 3)
           (pen-up) (move-to 0 25) (pen-down)
           (set-heading 180)
           (forward 120)
           (pen 1)
           (pen-up) (go-to 0 -45) (pen-down)
           (set-heading 45)
           (petal 40)
           ;; The petals, all the way round.
           (pen-up) (go-to 0 25) (pen-down)
           (color shade)
           (dotimes (i petals)
             (petal 55)
             (right (/ 360 petals)))
           (color :yellow)
           (dot 0 25 6)
           ;; Grass: the turtle's own shape, stamped in a row.
           (pen-up)
           (set-heading 0)
           (loop for x from -90 to 90 by 10
                 do (move-to x -96)
                    (hue (+ 0.25 (random 0.08)) 0.8 0.8)
                    (stamp))
           ;; And the turtle sits in the flower.
           (color :white)
           (go-to 0 25))
      (turtle-speed speed))))

(flower)
