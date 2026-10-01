;;; Rose -- r = cos kθ, the curve Guido Grandi called rhodonea.
;;;
;;; A whole number gives k petals when k is odd and 2k when it is even; a
;;; fraction gives something better.  Try (rose 4), (rose 7/2) and (rose 8/5).

(defun rose (&optional (k 5/3))
  (clear)
  (color :pink)
  (curve (lambda (a)
           (let ((r (* 92 (cos (* k a)))))
             (values (* r (cos a)) (* r (sin a)))))
         :to (* 2 pi (denominator (rationalize k)))
         :steps 900))

(rose)
