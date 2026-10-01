;;; Spiral -- a turtle that walks a little further every time it turns.
;;;
;;; The angle is everything.  Try (spiral 121), (spiral 144) and (spiral 91).

(defun spiral (&optional (angle 89))
  (clear)
  (dotimes (i 140)
    (hue (/ i 140))
    (forward i)
    (right angle)))

(spiral)
