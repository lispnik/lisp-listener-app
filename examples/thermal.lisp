;;; Thermal -- a hot plate, and an inspector taught to show it.
;;;
;;; DEFINE-VIEW gives your own data a picture, and DEFINE-CONTROLS gives it
;;; sliders.  (inspect *plate*) then shows the heat spreading, and moving a
;;; slider changes the plate and draws it again.

(defclass plate ()
  ((ambient :initform 20.0)             ; the edge is held at this
   (source :initform 90.0)))            ; and the middle at this

(defun temperatures (plate size steps)
  (with-slots (ambient source) plate
    (let ((cells (make-array (list size size) :initial-element ambient))
          (middle (floor size 2)))
      (dotimes (step steps cells)
        (setf (aref cells middle middle) source)
        (let ((next (make-array (list size size) :initial-element ambient)))
          (loop for r from 1 below (1- size)
                do (loop for c from 1 below (1- size)
                         do (setf (aref next r c)
                                  (/ (+ (aref cells (1- r) c) (aref cells (1+ r) c)
                                        (aref cells r (1- c)) (aref cells r (1+ c)))
                                     4))))
          (setf cells next))))))

(inspector:define-view (temperature :title "Temperature" :type plate :priority 20
                                    :options ((steps 150 :integer :min 10 :max 400)))
    (plate &key steps)
  (let ((cells (temperatures plate 24 steps))
        (side (/ 180 24)))
    (inspector:drawing
        (:fallback (format nil "A plate at ~a, heated to ~a in the middle."
                           (slot-value plate 'ambient) (slot-value plate 'source))
         ;; What to say about a point on the picture: the pointer, or a finger.
         :readout (lambda (x y)
                    (let ((c (floor (+ x 90) side))
                          (r (floor (+ y 90) side)))
                      (when (and (< -1 c 24) (< -1 r 24))
                        (format nil "~,1f degrees" (aref cells r c))))))
      (dotimes (r 24)
        (dotimes (c 24)
          (hue (* 0.66 (- 1 (max 0 (min 1 (/ (aref cells r c) 100))))))
          (box (- (* c side) 90) (- (* r side) 90) side side))))))

(inspector:define-controls (plate-controls :title "Plate" :type plate) (plate)
  (list (inspector:slider "Ambient" (inspector:slot-place plate 'ambient) :min 0 :max 60)
        (inspector:slider "Source" (inspector:slot-place plate 'source) :min 0 :max 100)))

(defparameter *plate* (make-instance 'plate))

(inspect *plate*)
