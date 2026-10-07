;;;; src/standard-views.lisp -- the views that come with the inspector.
;;;;
;;;; Written with INSPECTOR:DEFINE-VIEW and nothing else, so that this file is
;;;; also the worked example of contributing one: nothing here is reached by
;;;; any way a loaded system could not reach it too.
;;;;
;;;; Tables first -- an object's slots, a sequence's elements, a hash table's
;;;; entries, and the particulars of symbols, packages, classes, functions,
;;;; numbers, characters and pathnames -- and then the pictures: a byte
;;;; vector's histogram and hex, a plot of a vector of numbers, and a 2D array
;;;; of numbers as a heat map and as a surface.
;;;;
;;;; Priorities: the pictures are 10, so that they are what an inspector opens
;;;; on when they apply; the tables are 0, the more specific first; and
;;;; Describe, which applies to everything and says the least, is -20.

(in-package #:lisp-listener)

;;; Anything -------------------------------------------------------------------------

(defun instance-slot-names (object)
  (and (typep object '(or standard-object structure-object condition))
       (class-slot-names (class-of object))))

(inspector:define-view (object-view :title "Object" :type t)
    (object)
  "What it is, and its slots if it has any."
  (let ((slots (instance-slot-names object)))
    (inspector:stack
     (inspector:section
      "About"
      (inspector:table
       :columns '("" "")
       :rows (remove nil
                     (list (list "printed" (inspector-print object 200))
                           (list "type" (inspector-print (type-of object) 120))
                           (list "class" (inspector:value (class-of object)))
                           (let ((size (describe-size object)))
                             (and size (list "size" size)))))))
     (and slots
          (inspector:section
           "Slots"
           (inspector:table
            :columns '("Slot" "Value")
            :rows (loop for name in slots
                        collect (list (string-downcase name)
                                      (inspector:slot-place object name)))))))))

(inspector:define-view (describe-view :title "Describe" :type t :priority -20)
    (object)
  "What DESCRIBE says."
  (inspector:text "~a"
                  (string-trim '(#\Newline #\Space)
                               (with-output-to-string (stream)
                                 (describe object stream)))))

;;; Sequences and arrays -------------------------------------------------------------

(defun proper-list-p (object)
  (and (listp object) (ignore-errors (list-length object)) t))

(inspector:define-view (elements-view :title "Elements"
                                      :type (or cons vector)
                                      :when (lambda (object)
                                              (or (vectorp object) (proper-list-p object))))
    (sequence)
  "A list's or a vector's elements, each one a place."
  (if (listp sequence)
      (inspector:table
       :columns '("Index" "Value")
       :count (length sequence)
       :row (lambda (index)
              (list (format nil "[~d]" index)
                    (list-element-place sequence index))))
      (inspector:table
       :columns '("Index" "Value")
       :count (length sequence)
       :row (lambda (index)
              (list (format nil "[~d]" index)
                    (inspector:element-place sequence index))))))

(inspector:define-view (cons-view :title "Cons" :type cons
                                  :when (lambda (object) (not (proper-list-p object))))
    (cons)
  "A cons that is not a proper list: its car and its cdr."
  (inspector:table
   :columns '("" "Value")
   :rows (list (list "car" (inspector:place :label "car"
                                            :get (lambda () (car cons))
                                            :set (lambda (value) (setf (car cons) value))))
               (list "cdr" (inspector:place :label "cdr"
                                            :get (lambda () (cdr cons))
                                            :set (lambda (value) (setf (cdr cons) value)))))))

(inspector:define-view (entries-view :title "Entries" :type hash-table)
    (table)
  "A hash table's keys and values; each value a place."
  (let ((keys (coerce (loop for key being the hash-keys of table collect key) 'vector)))
    (inspector:stack
     (inspector:section
      "About"
      (inspector:table
       :rows (list (list "test" (inspector-print (hash-table-test table)))
                   (list "count" (format nil "~d" (hash-table-count table))))))
     (inspector:section
      "Entries"
      (inspector:table
       :columns '("Key" "Value")
       :count (length keys)
       :row (lambda (index)
              (let ((key (aref keys index)))
                (list (inspector:value key) (inspector:hash-place table key)))))))))

(defparameter *grid-columns* 12
  "How many columns of a 2D array the Grid view shows.")

(inspector:define-view (grid-view :title "Grid" :type (array * (* *)))
    (array)
  "A 2D array, a row to a row."
  (destructuring-bind (rows columns) (array-dimensions array)
    (let ((shown (min columns *grid-columns*)))
      (inspector:table
       :columns (cons "" (loop for column below shown collect (format nil "~d" column)))
       :count rows
       :row (lambda (row)
              (cons (format nil "[~d]" row)
                    (loop for column below shown
                          collect (inspector:aref-place array row column))))))))

;;; Symbols, packages, classes, functions --------------------------------------------

(inspector:define-view (symbol-view :title "Symbol" :type symbol)
    (symbol)
  "A symbol's name, package, value, function and property list."
  (inspector:table
   :columns '("" "Value")
   :rows (remove
          nil
          (list (list "name" (inspector:value (symbol-name symbol)))
                (list "package" (inspector:value (symbol-package symbol)))
                (list "value"
                      (if (constantp symbol)
                          (inspector:value (symbol-value symbol))
                          (make-instance 'symbol-value-place :symbol symbol :label "value")))
                (and (fboundp symbol)
                     (list "function"
                           (inspector:value (or (macro-function symbol)
                                                (and (not (special-operator-p symbol))
                                                     (fdefinition symbol))))))
                (and (symbol-plist symbol)
                     (list "plist" (inspector:value (symbol-plist symbol))))))))

(defclass symbol-value-place (inspector:place)
  ((symbol :initarg :symbol)))

(defmethod inspector:place-value ((place symbol-value-place))
  (symbol-value (slot-value place 'symbol)))

(defmethod (setf inspector:place-value) (value (place symbol-value-place))
  (setf (symbol-value (slot-value place 'symbol)) value))

(defmethod inspector:place-bound-p ((place symbol-value-place))
  (boundp (slot-value place 'symbol)))

(defmethod inspector:place-supports-p ((place symbol-value-place) operation)
  (member operation '(:set :remove)))

(defmethod place-remove ((place symbol-value-place))
  (makunbound (slot-value place 'symbol)))

(inspector:define-view (package-view :title "Package" :type package)
    (package)
  "A package: what it uses, and what it exports."
  (let ((externals (sort (let ((symbols '()))
                           (do-external-symbols (symbol package symbols)
                             (push symbol symbols)))
                         #'string< :key #'symbol-name)))
    (inspector:stack
     (inspector:section
      "About"
      (inspector:table
       :rows (list (list "name" (package-name package))
                   (list "nicknames" (format nil "~{~a~^, ~}" (package-nicknames package)))
                   (list "uses" (inspector:value (package-use-list package)))
                   (list "used by" (inspector:value (package-used-by-list package)))
                   (list "exports" (format nil "~d" (length externals))))))
     (inspector:section
      "Exported"
      (inspector:table
       :columns '("Symbol" "")
       :rows (loop for symbol in externals
                   collect (list (inspector:value symbol)
                                 (cond ((special-operator-p symbol) "special operator")
                                       ((macro-function symbol) "macro")
                                       ((fboundp symbol) "function")
                                       ((boundp symbol) "variable")
                                       ((find-class symbol nil) "class")
                                       (t "")))))))))

(defun class-rows (classes)
  "A row for each of CLASSES, to walk into: its name, and it."
  (loop for class in classes
        collect (list (class-label class) (inspector:value class (class-label class)))))

(defun nothing-rows (rows)
  (or rows (list (list "none" ""))))

(inspector:define-view (class-view :title "Class" :type class :priority 2)
    (class)
  "A class: what it is, and what it inherits from and is inherited by, each a
row to walk into."
  (let ((subclasses (coerce (sort (copy-list (class-direct-subclasses* class))
                                  #'string< :key #'class-label)
                            'vector)))
    (inspector:stack
     (inspector:section
      "About"
      (inspector:table
       :columns '("" "Value")
       :rows (remove nil
                     (list (list "name" (inspector:value (class-name class)))
                           (list "metaclass" (inspector:value (class-of class)))
                           (let ((documentation (ignore-errors (documentation class 't))))
                             (and documentation (list "documentation" documentation)))
                           (list "slots" (format nil "~d" (length (class-effective-slots* class))))
                           (list "methods"
                                 (format nil "~d" (length (specializer-direct-methods* class))))))))
     (inspector:section
      "Superclasses"
      (inspector:table :columns '("Class" "")
                       :rows (nothing-rows (class-rows (class-direct-superclasses* class)))))
     (inspector:section
      (format nil "Subclasses (~d)" (length subclasses))
      (if (zerop (length subclasses))
          (inspector:table :rows (nothing-rows '()))
          (inspector:table :columns '("Class" "")
                           :count (length subclasses)
                           :row (lambda (index)
                                  (first (class-rows (list (aref subclasses index)))))))))))

(defun slot-declarers (class name)
  "The classes in CLASS's precedence list that declare a slot NAME themselves,
most specific first, each with its direct slot definition: (CLASS . SLOT)."
  (loop for each in (class-precedence-list* class)
        for direct = (find name (class-direct-slots* each) :key #'slot-definition-name*)
        when direct collect (cons each direct)))

(defun slot-row (class slot)
  "The Slots view's row for SLOT, one of CLASS's effective slots."
  (let* ((name (slot-definition-name* slot))
         (declarers (slot-declarers class name))
         (from (or (car (first declarers)) class))
         (accessors (remove-duplicates
                     (loop for (nil . direct) in declarers
                           append (slot-definition-readers* direct)
                           append (slot-definition-writers* direct))
                     :test #'equal)))
    (flet ((printed (thing)
             (let ((*print-pretty* nil))
               (string-downcase (inspector-print thing 60)))))
      (list (string-downcase (symbol-name name))
            (class-label from)
            (printed (slot-definition-type* slot))
            (printed (slot-definition-allocation* slot))
            (format nil "~{~(~s~)~^ ~}" (slot-definition-initargs* slot))
            (if (slot-definition-initfunction* slot)
                (let ((*print-pretty* nil))
                  (inspector-print (slot-definition-initform* slot) 60))
                "")
            (format nil "~{~(~s~)~^ ~}" accessors)
            (inspector:value from (class-label from))))))

(inspector:define-view (slots-view :title "Slots" :type class)
    (class)
  "Every slot an instance of the class has, its own and inherited: where each
is declared -- the row to walk into -- its type, allocation, initargs,
initform, and the functions that read and write it."
  (inspector:table
   :columns '("Slot" "From" "Type" "Allocation" "Initargs" "Initform" "Accessors" "")
   :rows (nothing-rows
          (loop for slot in (class-effective-slots* class)
                collect (slot-row class slot)))))

(defun specializer-label (specializer)
  (if (typep specializer 'class)
      (class-label specializer)
      (let ((*print-pretty* nil))
        (string-downcase (inspector-print specializer 40)))))

(inspector:define-view (methods-view :title "Methods" :type class
                                     :when (lambda (class)
                                             (specializer-direct-methods* class)))
    (class)
  "The methods specialized on the class, by generic function: each row walks
into its generic function."
  (let ((rows (coerce
               (sort (loop for method in (specializer-direct-methods* class)
                           for function = (method-generic-function* method)
                           collect (list (let ((*print-pretty* nil))
                                           (string-downcase
                                            (inspector-print (generic-function-name* function) 60)))
                                         (format nil "~{~(~s~)~^ ~}" (method-qualifiers method))
                                         (format nil "~{~a~^, ~}"
                                                 (mapcar #'specializer-label
                                                         (method-specializers* method)))
                                         (inspector:value function)))
                     #'string< :key #'first)
               'vector)))
    (inspector:table :columns '("Generic function" "Qualifiers" "Specializers" "")
                     :count (length rows)
                     :row (lambda (index) (aref rows index)))))

(inspector:define-view (function-view :title "Function" :type function)
    (function)
  "A function's lambda list and documentation."
  (multiple-value-bind (arglist known) (function-arglist function)
    (inspector:table
     :columns '("" "Value")
     :rows (remove nil
                   (list (list "lambda list" (if known
                                                 (inspector-print arglist 200)
                                                 "not known"))
                         (let ((documentation (ignore-errors (documentation function t))))
                           (and documentation
                                (list "documentation" (clip-string documentation 400)))))))))

;;; Numbers, characters, strings, pathnames ------------------------------------------

(inspector:define-view (integer-view :title "Integer" :type integer)
    (integer)
  "An integer in the bases people read."
  (inspector:table
   :columns '("" "")
   :rows (list (list "decimal" (format nil "~d" integer))
               (list "hexadecimal" (format nil "~:[~;-~]#x~x" (minusp integer) (abs integer)))
               (list "octal" (format nil "~:[~;-~]#o~o" (minusp integer) (abs integer)))
               (list "binary" (clip-string (format nil "~:[~;-~]#b~b" (minusp integer)
                                                   (abs integer))
                                           200))
               (list "bits" (format nil "~d" (integer-length integer))))))

(inspector:define-view (float-view :title "Float" :type float)
    (float)
  "A float taken apart."
  (multiple-value-bind (significand exponent sign) (integer-decode-float float)
    (inspector:table
     :columns '("" "")
     :rows (list (list "type" (inspector-print (type-of float)))
                 (list "sign" (format nil "~d" sign))
                 (list "significand" (format nil "~d" significand))
                 (list "exponent" (format nil "~d" exponent))
                 (list "exactly" (inspector:value (rational float)))))))

(inspector:define-view (ratio-view :title "Ratio" :type ratio)
    (ratio)
  "A ratio's two halves, and roughly what it comes to."
  (inspector:table
   :columns '("" "")
   :rows (list (list "numerator" (inspector:value (numerator ratio)))
               (list "denominator" (inspector:value (denominator ratio)))
               (list "roughly" (format nil "~f" (float ratio 1d0))))))

(inspector:define-view (complex-view :title "Complex" :type complex)
    (number)
  "A complex number's parts, and where it is."
  (inspector:table
   :columns '("" "")
   :rows (list (list "real part" (inspector:value (realpart number)))
               (list "imaginary part" (inspector:value (imagpart number)))
               (list "magnitude" (format nil "~f" (abs number)))
               (list "phase" (format nil "~f" (phase number))))))

(inspector:define-view (character-view :title "Character" :type character)
    (character)
  "A character's code and name."
  (inspector:table
   :columns '("" "")
   :rows (list (list "code" (format nil "~d" (char-code character)))
               (list "hexadecimal" (format nil "U+~4,'0x" (char-code character)))
               (list "name" (or (char-name character) "none")))))

(inspector:define-view (string-view :title "Text" :type string :priority 5)
    (string)
  "A string, as what it says."
  (inspector:text "~a" string))

(inspector:define-view (pathname-view :title "Pathname" :type pathname)
    (pathname)
  "A pathname's components, and whether there is such a file."
  (inspector:table
   :columns '("" "")
   :rows (list (list "namestring" (inspector-print (ignore-errors (namestring pathname))))
               (list "directory" (inspector:value (pathname-directory pathname)))
               (list "name" (inspector:value (pathname-name pathname)))
               (list "type" (inspector:value (pathname-type pathname)))
               (list "exists" (if (ignore-errors (probe-file pathname)) "yes" "no")))))

;;; Pictures -------------------------------------------------------------------------

(defun bar-heights (counts log-scale)
  "COUNTS as heights from 0 to 1."
  (let* ((scaled (map 'vector (lambda (count)
                                (if log-scale (log (1+ count)) count))
                      counts))
         (most (reduce #'max scaled :initial-value 0)))
    (if (plusp most)
        (map 'vector (lambda (value) (/ value most)) scaled)
        scaled)))

(inspector:define-view (histogram-view
                        :title "Histogram"
                        :type (vector (unsigned-byte 8))
                        :priority 10
                        :options ((bins 32 :integer :min 4 :max 256)
                                  (log-scale nil :boolean)))
    (bytes &key bins log-scale)
  "How often each byte value turns up."
  (let ((counts (make-array bins :initial-element 0)))
    (loop for byte across bytes
          do (incf (aref counts (min (1- bins) (floor (* byte bins) 256)))))
    (let ((heights (bar-heights counts log-scale))
          (width (/ 180d0 bins)))
      (inspector:drawing
          (:fallback (format nil "~d byte~:p in ~d bins; the fullest holds ~d."
                             (length bytes) bins (reduce #'max counts :initial-value 0))
           :readout (lambda (x y)
                      (declare (ignore y))
                      (let ((bin (floor (+ x 90) width)))
                        (when (< -1 bin bins)
                          (format nil "bytes ~d to ~d: ~d"
                                  (ceiling (* bin 256) bins)
                                  (1- (ceiling (* (1+ bin) 256) bins))
                                  (aref counts bin))))))
        (canvas:color :gray)
        (canvas:line -90 -80 90 -80)
        (loop for index from 0 below bins
              for height across heights
              do (canvas:hue (* 0.7 (/ index bins)))
                 (canvas:box (+ -90 (* index width)) -80
                             (max 0.5 (- width 0.6)) (* 150 height)))
        (canvas:color :white)
        (canvas:text -90 -94 "0" 6)
        (canvas:text 78 -94 "255" 6)
        (canvas:text -90 84 (format nil "~d bytes~:[~;, log scale~]" (length bytes) log-scale) 6)))))

(inspector:define-view (hex-view
                        :title "Hex"
                        :type (vector (unsigned-byte 8))
                        :priority 10
                        :options ((width 16 :choice (8 16 32))))
    (bytes &key width)
  "The bytes, a row at a time: offset, hex, and the characters they would be."
  (inspector:table
   :columns '("Offset" "Hex" "Text")
   :count (ceiling (length bytes) width)
   :row (lambda (row)
          (let* ((start (* row width))
                 (end (min (length bytes) (+ start width))))
            (list (format nil "~8,'0x" start)
                  (format nil "~{~2,'0x~^ ~}" (coerce (subseq bytes start end) 'list))
                  (map 'string (lambda (byte)
                                 (if (<= 32 byte 126) (code-char byte) #\.))
                       (subseq bytes start end)))))))

(defun real-vector-p (object)
  "Whether OBJECT is a vector of real numbers worth plotting.  By its element
type where that says so; by looking at the first few where it does not."
  (and (vectorp object) (not (stringp object))
       (> (length object) 1)
       (or (subtypep (array-element-type object) 'real)
           (every #'realp (subseq object 0 (min 64 (length object)))))))

(defun real-range (reals)
  "The least and the greatest of REALS, a sequence, as two values."
  (let ((low nil) (high nil))
    (map nil (lambda (value)
               (when (realp value)
                 (when (or (null low) (< value low)) (setf low value))
                 (when (or (null high) (> value high)) (setf high value))))
         reals)
    (values (or low 0) (or high 0))))

(inspector:define-view (plot-view :title "Plot" :type vector :when #'real-vector-p
                                  :priority 10)
    (vector)
  "A vector of numbers, as a line."
  (multiple-value-bind (low high) (real-range vector)
    (let* ((span (if (= high low) 1 (- high low)))
           (count (length vector))
           ;; No more points than there are points across to put them on.
           (step (max 1 (ceiling count 400))))
      (inspector:drawing
          (:fallback (format nil "~d number~:p, from ~a to ~a." count low high)
           :readout (lambda (x y)
                      (declare (ignore y))
                      (let ((index (round (* (/ (+ x 90) 180) (1- count)))))
                        (when (< -1 index count)
                          (format nil "[~d] = ~a" index
                                  (inspector-print (aref vector index) 40))))))
        (canvas:color :gray)
        (canvas:rect -90 -80 180 160)
        (canvas:color :cyan)
        (loop with previous = nil
              for index from 0 below count by step
              for value = (aref vector index)
              for x = (+ -90 (* 180 (/ index (max 1 (1- count)))))
              for y = (and (realp value) (+ -80 (* 160 (/ (- value low) span))))
              do (when (and previous y)
                   (canvas:line (car previous) (cdr previous) x y))
                 (setf previous (and y (cons x y))))
        (canvas:color :white)
        (canvas:text -90 84 (format nil "~a" (inspector-print high 24)) 6)
        (canvas:text -90 -94 (format nil "~a" (inspector-print low 24)) 6)))))

(defun real-matrix-p (object)
  "Whether OBJECT is a 2D array of real numbers, with something in it."
  (and (arrayp object)
       (= 2 (array-rank object))
       (plusp (array-total-size object))
       (or (subtypep (array-element-type object) 'real)
           (loop for index below (min 64 (array-total-size object))
                 always (realp (row-major-aref object index))))))

(defun matrix-range (matrix)
  (let ((low nil) (high nil))
    (dotimes (index (array-total-size matrix))
      (let ((value (row-major-aref matrix index)))
        (when (realp value)
          (when (or (null low) (< value low)) (setf low value))
          (when (or (null high) (> value high)) (setf high value)))))
    (values (or low 0) (or high 0))))

(defun set-map-color (colormap fraction)
  "Draw in the colour COLORMAP gives FRACTION, from 0 to 1."
  (let ((fraction (max 0 (min 1 fraction))))
    (ecase colormap
      (:heat (canvas:hue (* 0.66 (- 1 fraction))))
      (:gray (canvas:color fraction fraction fraction))
      (:fire (canvas:color (min 1 (* 3 fraction))
                           (max 0 (min 1 (- (* 3 fraction) 1)))
                           (max 0 (- (* 3 fraction) 2)))))))

(defparameter *picture-cells* 48
  "The most rows or columns of an array a picture draws; a bigger one is sampled.")

(inspector:define-view (heat-map-view
                        :title "Heat map"
                        :type (array * (* *))
                        :when #'real-matrix-p
                        :priority 10
                        :options ((colormap :heat :choice (:heat :gray :fire))))
    (matrix &key colormap)
  "A 2D array of numbers, each a coloured square: cold to hot."
  (destructuring-bind (rows columns) (array-dimensions matrix)
    (multiple-value-bind (low high) (matrix-range matrix)
      (let* ((span (if (= high low) 1 (- high low)))
             (row-step (max 1 (ceiling rows *picture-cells*)))
             (column-step (max 1 (ceiling columns *picture-cells*)))
             (shown-rows (ceiling rows row-step))
             (shown-columns (ceiling columns column-step))
             (side (/ 180d0 (max shown-rows shown-columns))))
        (inspector:drawing
            (:fallback (format nil "~d × ~d numbers, from ~a to ~a." rows columns low high)
             :readout (lambda (x y)
                        (let ((c (floor (+ x 90) side))
                              (r (floor (- 90 y) side)))
                          (when (and (< -1 r shown-rows) (< -1 c shown-columns))
                            (format nil "[~d ~d] = ~a" (* r row-step) (* c column-step)
                                    (inspector-print
                                     (aref matrix (* r row-step) (* c column-step))
                                     40))))))
          (loop for r from 0 below shown-rows
                do (loop for c from 0 below shown-columns
                         for value = (aref matrix (* r row-step) (* c column-step))
                         do (when (realp value)
                              (set-map-color colormap (/ (- value low) span))
                              ;; Row 0 at the top, as an array is written.
                              (canvas:box (+ -90 (* c side))
                                          (- 90 (* (1+ r) side))
                                          side side))))
          (canvas:color :white)
          (canvas:text -90 -99 (format nil "~a … ~a" (inspector-print low 16)
                                       (inspector-print high 16))
                       6))))))

(inspector:define-view (surface-view
                        :title "Surface"
                        :type (array * (* *))
                        :when #'real-matrix-p
                        :priority 10
                        :options ((yaw 35 :integer :min 0 :max 360)
                                  (pitch 30 :integer :min 5 :max 85)
                                  (z-scale 1.0 :number :min 0.1 :max 4.0)))
    (matrix &key yaw pitch z-scale)
  "A 2D array of numbers as a surface: its height is the number."
  (destructuring-bind (rows columns) (array-dimensions matrix)
    (multiple-value-bind (low high) (matrix-range matrix)
      (let* ((span (if (= high low) 1 (- high low)))
             (cells 28)
             (row-step (max 1 (ceiling rows cells)))
             (column-step (max 1 (ceiling columns cells)))
             (shown-rows (ceiling rows row-step))
             (shown-columns (ceiling columns column-step))
             (yaw-radians (* yaw (/ pi 180)))
             (pitch-radians (* pitch (/ pi 180))))
        (flet ((height (r c)
                 (let ((value (aref matrix (* r row-step) (* c column-step))))
                   (if (realp value) (/ (- value low) span) 0)))
               ;; A point on the unit square, raised by its height, turned
               ;; about the vertical by YAW and tipped towards the eye by PITCH.
               (project (r c z)
                 (let* ((x (- (/ c (max 1 (1- shown-columns))) 0.5))
                        (y (- 0.5 (/ r (max 1 (1- shown-rows)))))
                        (turned-x (- (* x (cos yaw-radians)) (* y (sin yaw-radians))))
                        (turned-y (+ (* x (sin yaw-radians)) (* y (cos yaw-radians)))))
                   (cons (* 120 turned-x)
                         (+ -30
                            (* 120 turned-y (sin pitch-radians))
                            (* 70 z z-scale (cos pitch-radians)))))))
          (inspector:drawing
              (:fallback (format nil "~d × ~d numbers, from ~a to ~a." rows columns low high))
            (dotimes (r shown-rows)
              (dotimes (c shown-columns)
                (let* ((z (height r c))
                       (here (project r c z)))
                  (canvas:hue (* 0.66 (- 1 z)))
                  (when (< (1+ c) shown-columns)
                    (let ((there (project r (1+ c) (height r (1+ c)))))
                      (canvas:line (car here) (cdr here) (car there) (cdr there))))
                  (when (< (1+ r) shown-rows)
                    (let ((there (project (1+ r) c (height (1+ r) c))))
                      (canvas:line (car here) (cdr here) (car there) (cdr there)))))))))))))

;;; More particulars -----------------------------------------------------------------

(defun subclass-rows (class depth limit)
  "Rows for CLASS's subclasses, and theirs, indented, LIMIT levels down."
  (when (< depth limit)
    (loop for name in (sort (copy-list (class-direct-subclass-names class)) #'string<
                            :key #'symbol-name)
          for subclass = (find-class name nil)
          when subclass
            append (cons (list (format nil "~v@{  ~}~(~a~)" (1+ depth) name)
                               (inspector:value subclass))
                         (subclass-rows subclass (1+ depth) limit)))))

(inspector:define-view (hierarchy-view :title "Hierarchy" :type class
                                       :options ((depth 3 :integer :min 1 :max 8)))
    (class &key depth)
  "A class among its relations: what it inherits from, most specific first,
and what inherits from it, as a tree.  Every one is a row to walk into."
  (inspector:stack
   (inspector:section
    "Inherits from"
    (inspector:table
     :columns '("Class" "")
     :rows (loop for name in (rest (class-precedence-names class))
                 for super = (find-class name nil)
                 when super
                   collect (list (string-downcase name) (inspector:value super)))))
   (inspector:section
    "Inherited by"
    (inspector:table
     :rows (or (subclass-rows class 0 depth)
               (list (list "nothing" "")))))))

(inspector:define-view (condition-view :title "Condition" :type condition :priority 5)
    (condition)
  "A condition: what it says, and what kind of thing it is."
  (inspector:stack
   (inspector:text "~a" (report-condition condition))
   (inspector:section
    "About"
    (inspector:table
     :columns '("" "")
     :rows (list (list "type" (inspector-print (type-of condition) 120))
                 (list "an error" (if (typep condition 'error) "yes" "no"))
                 (list "a warning" (if (typep condition 'warning) "yes" "no"))
                 (list "inherits from"
                       (inspector:value
                        (rest (class-precedence-names (class-of condition))))))))))

(inspector:define-view (disassembly-view :title "Disassembly" :type function :priority -10
                                         :when #'function-disassembly)
    (function)
  "What the compiler made of it, where the Lisp will say."
  (inspector:text "~a" (function-disassembly function)))

(defun string-lines (string)
  (loop with start = 0
        for newline = (position #\Newline string :start start)
        collect (subseq string start newline)
        while newline
        do (setf start (1+ newline))))

(inspector:define-view (lines-view :title "Lines" :type string :priority 6
                                   :when (lambda (string) (find #\Newline string)))
    (string)
  "A string of several lines, a row a line."
  (let ((lines (coerce (string-lines string) 'vector)))
    (inspector:table
     :columns '("Line" "Text")
     :count (length lines)
     :row (lambda (index)
            (list (format nil "~d" (1+ index)) (aref lines index))))))

;;; A pointer ------------------------------------------------------------------------
;;;
;;; Shown as an address, and never sent a message: see INSPECTOR:OBJC in
;;; src/places.lisp for why.  The button is how a person says "this one is an
;;; Objective-C object", which is theirs to know.

(defun non-null-pointer-p (object)
  (and (cffi:pointerp object) (not (cffi:null-pointer-p object))))

(inspector:define-view (pointer-view :title "Pointer" :type t :priority 5
                                     :when #'cffi:pointerp)
    (pointer)
  "A foreign pointer: where it points, and nothing about what is there."
  (inspector:stack
   (inspector:table
    :columns '("" "")
    :rows (list (list "address" (format nil "#x~x" (cffi:pointer-address pointer)))
                (list "null" (if (cffi:null-pointer-p pointer) "yes" "no"))))
   (inspector:text "What is at an address cannot be told from the address.  If this is an
Objective-C object, say so -- the button in the panel, or
(inspect (inspector:objc pointer)) -- and it is shown as one.  If it is not,
saying so will crash the program.")))

(inspector:define-controls (pointer-controls :title "Pointer" :when #'non-null-pointer-p)
    (pointer)
  (list (inspector:button "Treat as Objective-C object"
                          (lambda ()
                            (inspector:open-object (inspector:objc pointer)
                                                   "as an object")))))
