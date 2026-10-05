;;;; src/macos/heml-demo.lisp -- the demo's editor scene.
;;;;
;;;; Played by RUN-DEMO when the image has lisp-listener/heml loaded: (ed
;;;; "file") at the prompt, an edit typed into heml a key at a time, Evaluate
;;;; Defun redefining at the listener's prompt what the demo defined there
;;;; earlier, and the new definition called.  heml's window is laid over the
;;;; top of the listener's, leaving the foot of the transcript -- where the
;;;; answers arrive -- in the picture.

(in-package #:lisp-listener)

(pushnew 'heml-window *demo-overlays*)

(defun demo-heml-text (file)
  "The text of heml's buffer on FILE, or NIL.  Read from thread 1 while heml's
own thread may be changing it, so only ever to wait on."
  (let ((buffer (heml-file-buffer file)))
    (and buffer (ignore-errors (hi::region-to-string (hi::buffer-region buffer))))))

(defun demo-heml-type (text file &key (per-key 0.06d0))
  "Type TEXT into heml a key at a time, through the hook a keypress reaches,
waiting for each to be in the buffer before photographing it."
  (let ((view (heml.cocoa::display-view heml.cocoa::*display*)))
    (loop for i from 1 to (length text)
          for typed = (subseq text 0 i)
          do (objc:invoke view "insertText:replacementRange:" (string (char text (1- i)))
                          (cons #x7FFFFFFFFFFFFFFF 0))
             (demo-expect (wait-for (lambda () (search typed (or (demo-heml-text file) "")))
                                    :timeout 10)
                          (format nil "~s in heml's buffer" typed))
             (pump 0.04d0)
             (demo-frame per-key))))

(defun demo-place-heml (listener)
  "heml's window over the top of the listener's, below its title bar."
  (let ((frame (objc:invoke (listener-window listener) "frame"))
        (height 300d0))
    (objc:invoke (heml-window) "setFrame:display:"
                 (vector (+ (aref frame 0) 16d0)
                         (- (+ (aref frame 1) (aref frame 3)) 44d0 height)
                         (- (aref frame 2) 32d0) height)
                 t)))

(defun demo-editor (listener)
  "The editor: open a file, change GREET in it, evaluate it at the prompt."
  (let* ((file (merge-pathnames "greet.lisp" *demo-directory*))
         (defaults *default-pathname-defaults*))
    (with-open-file (out file :direction :output :if-exists :supersede)
      (format out "(in-package :cl-user)~%~%(defun greet (name)~%  (format nil \"Hello, ~~a\" name))~%"))
    ;; So that what is typed is (ed "greet.lisp"), not a runner's long path.
    ;; The listener thread does not bind it, so it sees this.
    (setf *default-pathname-defaults* (pathname *demo-directory*))
    (unwind-protect
         (progn
           (demo-caption "(ed \"file\") opens heml, an Emacs-style editor written in Lisp, in the same application")
           (demo-type "(ed \"greet.lisp\")")
           (objc:invoke (demo-view) "insertNewline:" (cffi:null-pointer))
           (demo-expect (wait-for (lambda () (and (heml.cocoa:hosted-running-p)
                                                  (live-pointer-p (heml-window))
                                                  (demo-heml-text file)))
                                  :timeout 30)
                        "heml, on greet.lisp")
           (demo-place-heml listener)
           (demo-at-prompt)
           (pump-for 0.6d0)
           (demo-frame 2.6d0)
           (demo-caption "Its keys are Emacs's; here, an edit to GREET")
           (post-to-heml (list :goto-line 4))
           (post-to-heml (list :command "End of Line"))
           (pump-for 0.3d0)
           (demo-frame 0.6d0)
           ;; Back over `" name))', to just inside the string.
           (dotimes (i 8)
             (post-to-heml (list :command "Backward Character"))
             (pump 0.08d0)
             (demo-frame 0.08d0))
           (demo-heml-type "! Welcome back" file)
           (demo-frame 1.0d0)
           (demo-caption "Evaluate Defun sends the form to the listener's prompt, and GREET is redefined")
           (let ((before (length (transcript-text listener))))
             (post-to-heml (list :command "Evaluate Defun"))
             (demo-expect (wait-for (lambda () (search "GREET" (transcript-text listener)
                                                       :start2 before))
                                    :timeout 15)
                          "GREET evaluated from heml"))
           (demo-at-prompt)
           (pump-for 0.4d0)
           (demo-frame 2.6d0)
           (demo-caption "The new definition, at once")
           (demo-type "(greet \"Lisp\")")
           (demo-return "Welcome back" :hold 2.4d0)
           ;; Saved and put away, so that the rest of the demo is the listener's
           ;; and quitting has nothing to ask about.
           (post-to-heml (list :command "Save File"))
           (wait-for (lambda () (search "Welcome back" (read-file-text file))) :timeout 10)
           (objc:invoke (objc:invoke (heml-window) "delegate") "windowShouldClose:" (heml-window))
           (pump-for 0.3d0)
           (demo-frame 0.8d0))
      (setf *default-pathname-defaults* defaults))))
