;;;; src/class-graph.lisp -- a class among its relations, drawn.
;;;;
;;;; The Graph view: the class in the middle, everything it inherits from above
;;;; it -- a DAG, since a class may have several superclasses -- and what
;;;; inherits from it below, DEPTH levels down.  A node is a class to walk into:
;;;; the drawing's :OPEN answers the class under a click or a tap, and its
;;;; :READOUT says what the class is.
;;;;
;;;; Laid out here, in Lisp, and drawn with the canvas's own shapes, so that
;;;; both painters draw it and `make test' can read it.  No toolkit has a
;;;; graph to lend: Swift Charts plots data and is out of reach of the
;;;; Objective-C runtime besides.  A drawing cannot scroll, so what keeps the
;;;; graph readable is the cap on each layer below: past WIDTH-LIMIT, the rest
;;;; are one node, "+N more", which opens as a list of them.

(in-package #:lisp-listener)

(defstruct (graph-node (:conc-name node-))
  class                                 ; NIL for a "+N more"
  (more '())                            ; the classes a "+N more" stands for
  (layer 0)                             ; 0 the class; up is negative
  (order 0d0)                           ; place in the layer, while ordering
  (x 0d0) (y 0d0)                       ; the centre, in the canvas's units
  (width 0d0) (height 0d0)
  (label "")
  (size 7d0))                           ; of the label's type

(defun class-label (class)
  "CLASS's name, as it would be typed in the current package."
  (let ((name (ignore-errors (class-name class))))
    (if name
        (string-downcase (let ((*print-pretty* nil)) (prin1-to-string name)))
        "(anonymous)")))

(defun class-graph (class &key (depth 2) (width-limit 10))
  "The nodes of CLASS's graph and its edges, as two values.  An edge is
(SUBCLASS-NODE . SUPERCLASS-NODE).

Every class CLASS inherits from is there, at the layer of its LONGEST path from
CLASS, so that every edge between ancestors points up.  The precedence list is
in an order where a class comes before its superclasses, which is the order to
settle those lengths in.  Below, its subclasses to DEPTH, breadth first, each
class once, and at most WIDTH-LIMIT in a layer."
  (let* ((nodes (make-hash-table :test 'eq))
         (focus (make-graph-node :class class :layer 0))
         (precedence (or (class-precedence-list* class) (list class)))
         (ancestors (remove class precedence))
         (all (list focus)))
    (setf (gethash class nodes) focus)
    ;; Up: the longest path, in precedence order.
    (let ((distance (make-hash-table :test 'eq)))
      (setf (gethash class distance) 0)
      (dolist (each (cons class ancestors))
        (let ((here (gethash each distance)))
          (when here
            (dolist (super (class-direct-superclasses* each))
              (when (member super ancestors)
                (setf (gethash super distance)
                      (max (gethash super distance 0) (1+ here))))))))
      (loop for ancestor in ancestors
            for index from 0
            for node = (make-graph-node :class ancestor
                                        :layer (- (gethash ancestor distance 1))
                                        :order (float index 1d0))
            do (setf (gethash ancestor nodes) node)
               (push node all)))
    ;; Down: breadth first, capped.
    (loop with parents = (list class)
          for layer from 1 to depth
          for children = (sort (remove-duplicates
                                (loop for parent in parents
                                      append (remove-if (lambda (child) (gethash child nodes))
                                                        (class-direct-subclasses* parent))))
                               #'string< :key #'class-label)
          while children
          do (let* ((shown (if (> (length children) width-limit)
                               (subseq children 0 (1- width-limit))
                               children))
                    (rest (nthcdr (length shown) children)))
               (loop for child in shown
                     for index from 0
                     for node = (make-graph-node :class child :layer layer
                                                 :order (float index 1d0))
                     do (setf (gethash child nodes) node)
                        (push node all))
               (when rest
                 (push (make-graph-node :more rest :layer layer
                                        :order (float (length shown) 1d0))
                       all))
               (setf parents shown)))
    (setf all (nreverse all))
    (values all
            (loop for node in all
                  for class = (node-class node)
                  when class
                    append (loop for super in (class-direct-superclasses* class)
                                 for above = (gethash super nodes)
                                 when above
                                   collect (cons node above))))))

(defun graph-layers (nodes)
  "NODES as a list of layers, top first, each in its order."
  (let ((layers (sort (remove-duplicates (mapcar #'node-layer nodes)) #'<)))
    (loop for layer in layers
          collect (sort (remove-if-not (lambda (node) (= (node-layer node) layer)) nodes)
                        #'< :key #'node-order))))

(defun order-layers (layers edges)
  "Reorder each layer by where its neighbours are -- the mean of their places
in the layers above and below -- which uncrosses most of what crosses.  Down
and up again, three times.  A \"+N more\" stays at the end of its layer."
  (flet ((sweep (layers)
           (loop for (above layer) on layers
                 while layer
                 do (dolist (node layer)
                      (let ((neighbours
                              (loop for (from . to) in edges
                                    when (and (eq from node) (member to above)) collect to
                                    when (and (eq to node) (member from above)) collect from)))
                        (when neighbours
                          (setf (node-order node)
                                (/ (reduce #'+ neighbours :key #'node-order)
                                   (length neighbours))))))
                    (let ((sorted (stable-sort (copy-list layer)
                                               (lambda (a b)
                                                 (cond ((node-more a) nil)
                                                       ((node-more b) t)
                                                       (t (< (node-order a) (node-order b))))))))
                      (loop for node in sorted
                            for index from 0
                            do (setf (node-order node) (float index 1d0)))
                      (replace layer sorted)))))
    (dotimes (i 3)
      (sweep layers)
      (sweep (reverse layers)))
    (mapcar (lambda (layer) (sort layer #'< :key #'node-order)) layers)))

(defun fit-label (text size width)
  "TEXT, cut short with an ellipsis if it would not fit WIDTH at SIZE."
  (let ((room (max 1 (floor (- width 3) (* 0.62 size)))))
    (if (<= (length text) room)
        text
        (concatenate 'string (subseq text 0 (max 0 (1- room))) "…"))))

(defun layout-class-graph (class &key (depth 2) (width-limit 10))
  "CLASS's graph, laid out in -95..95 each way.  Answers the nodes, each with
its centre, size and label, and the edges, as two values."
  (multiple-value-bind (nodes edges) (class-graph class :depth depth :width-limit width-limit)
    (let* ((layers (order-layers (graph-layers nodes) edges))
           (count (length layers))
           (step (if (> count 1) (min 45d0 (/ 190d0 (1- count))) 0d0))
           (top (* step (1- count) 0.5d0))
           (height (min 14d0 (max 6d0 (* step 0.55d0))))
           (size (min 7d0 (max 3d0 (* height 0.55d0)))))
      (loop for layer in layers
            for row from 0
            for y = (- top (* row step))
            for slot = (/ 190d0 (length layer))
            do (loop for node in layer
                     for index from 0
                     for text = (if (node-class node)
                                    (class-label (node-class node))
                                    (format nil "+~d more" (length (node-more node))))
                     for width = (min (* slot 0.92d0) (+ 6d0 (* 0.62d0 size (length text))))
                     do (setf (node-x node) (+ -95d0 (* slot (+ index 0.5d0)))
                              (node-y node) y
                              (node-width node) width
                              (node-height node) height
                              (node-size node) size
                              (node-label node) (fit-label text size width))))
      (values nodes edges))))

(defun node-at (nodes x y)
  "The node whose box (X, Y) is in, or NIL."
  (find-if (lambda (node)
             (and (<= (abs (- x (node-x node))) (+ 1 (/ (node-width node) 2)))
                  (<= (abs (- y (node-y node))) (+ 1 (/ (node-height node) 2)))))
           nodes))

(defun class-kind-hue (class)
  "A hue for the kind of class: standard, structure, built in, or a condition."
  (let ((metaclass (ignore-errors (class-name (class-of class)))))
    (cond ((subtypep class 'condition) 0.02)
          ((eq metaclass 'structure-class) 0.33)
          ((eq metaclass 'built-in-class) 0.12)
          (t 0.6))))

(defun describe-graph-node (node)
  "What the readout says of NODE."
  (let ((class (node-class node)))
    (if class
        (format nil "~a: ~(~a~), ~d slot~:p, ~d subclass~:*~[es~;~:;es~]"
                (class-label class)
                (ignore-errors (class-name (class-of class)))
                (length (class-effective-slots* class))
                (length (class-direct-subclasses* class)))
        (format nil "~d more: ~{~a~^, ~}~:[~;, …~]"
                (length (node-more node))
                (mapcar #'class-label (subseq (node-more node) 0 (min 4 (length (node-more node)))))
                (> (length (node-more node)) 4)))))

(defun draw-class-graph (class nodes edges)
  "Draw NODES and EDGES with the canvas's functions: the edges first, each with
a head at the superclass, and the boxes over them."
  (canvas:pen 0.6)
  (canvas:color 0.7 0.7 0.7)
  (loop for (from . to) in edges
        for x1 = (node-x from)
        for y1 = (+ (node-y from) (/ (node-height from) 2))
        for x2 = (node-x to)
        for y2 = (- (node-y to) (/ (node-height to) 2))
        do (canvas:line x1 y1 x2 y2)
           (let* ((angle (atan (- y1 y2) (- x1 x2)))
                  (head 2.5d0))
             (dolist (turn '(0.45d0 -0.45d0))
               (canvas:line x2 y2
                            (+ x2 (* head (cos (+ angle turn))))
                            (+ y2 (* head (sin (+ angle turn))))))))
  (dolist (node nodes)
    (let ((left (- (node-x node) (/ (node-width node) 2)))
          (bottom (- (node-y node) (/ (node-height node) 2)))
          (focus (eq (node-class node) class)))
      (cond ((node-more node) (canvas:color 0.3 0.3 0.3))
            (focus (canvas:hue (class-kind-hue class) 0.7 0.85))
            (t (canvas:hue (class-kind-hue (node-class node)) 0.45 0.45)))
      (canvas:box left bottom (node-width node) (node-height node))
      (canvas:color (if focus :black :white))
      (canvas:text (+ left 3) (- (node-y node) (* 0.35 (node-size node)))
                   (node-label node) (node-size node)))))

(inspector:define-view (class-graph-view :title "Graph" :type class :priority 1
                                         :options ((depth 2 :integer :min 0 :max 4)))
    (class &key depth)
  "The class among its relations, drawn: what it inherits from above it, and
what inherits from it below.  Click a class to inspect it."
  (multiple-value-bind (nodes edges) (layout-class-graph class :depth depth)
    (inspector:drawing
        (:fallback (format nil "~a: ~d class~:*~[es~;~:;es~] above it, ~d below it to depth ~d."
                           (class-label class)
                           (count-if (lambda (node) (minusp (node-layer node))) nodes)
                           (count-if (lambda (node) (plusp (node-layer node))) nodes)
                           depth)
         :readout (lambda (x y)
                    (let ((node (node-at nodes x y)))
                      (and node (describe-graph-node node))))
         :open (lambda (x y)
                 (let ((node (node-at nodes x y)))
                   (cond ((null node) nil)
                         ((node-class node)
                          (values (node-class node) (class-label (node-class node))))
                         (t (values (copy-list (node-more node))
                                    (format nil "~d more" (length (node-more node)))))))))
      (draw-class-graph class nodes edges))))
