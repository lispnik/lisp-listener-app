;;; Tree -- every branch is a smaller tree.
;;;
;;; BRANCH draws one branch, then calls itself twice for the two that grow from
;;; its end, and walks back to where it started.  Try (tree 35) and (tree 12).

(defun branch (length angle)
  (when (> length 3)
    (pen (/ length 9))
    (hue (- 0.33 (/ length 200)))
    (forward length)
    (left angle)
    (branch (* length 0.72) angle)
    (right (* 2 angle))
    (branch (* length 0.72) angle)
    (left angle)
    (pen-up)
    (back length)
    (pen-down)))

(defun tree (&optional (angle 24))
  (clear)
  (move-to 0 -92)
  (branch 50 angle)
  (pen 1))

(tree)
