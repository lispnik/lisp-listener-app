;;; Doodle -- draw with the mouse, or a finger, for twenty seconds.
;;;
;;; (pointer) says where it is and whether it is down.  A line goes from where
;;; it was to where it is, and the colour goes round with time.  Try (doodle 60).

(defun doodle (&optional (seconds 20))
  (clear)
  (show)
  (color :gray)
  (text -34 88 "draw here" 8)
  (pen 2)
  (let ((was nil))
    (dotimes (tick (* seconds 50))
      (when (eq (key) :escape)
        (return))
      (multiple-value-bind (x y down) (pointer)
        (cond (down
               (when was
                 (hue (/ tick 300))
                 (line (car was) (cdr was) x y))
               (setf was (cons x y)))
              (t
               (setf was nil))))
      (wait 0.02)))
  (pen 1))

(doodle)
