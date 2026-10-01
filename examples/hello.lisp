;;; Hello -- a face, and where things are on the canvas.
;;;
;;; The canvas runs from -100 to 100 each way.  (0, 0) is the middle and y goes
;;; up, as it does in mathematics.  Change a number and run it again.

(clear)
(color :yellow)
(circle 0 0 60)
(dot -22 20 7)
(dot 22 20 7)
(pen 3)
(curve (lambda (a) (values (* 36 (cos a)) (* 36 (sin a))))
       :from (* pi 1.15) :to (* pi 1.85))
(pen 1)
(color :white)
(text -44 -92 "hello, world" 10)
