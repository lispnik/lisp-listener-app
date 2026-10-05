;;;; src/macos/heml-test.lisp -- the debugger test's heml section.
;;;;
;;;; Run by RUN-DEBUGGER-TEST when the image has lisp-listener/heml loaded:
;;;; heml opened in this application on a file, as (ed ...) opens it; the
;;;; application's delegate and its menu bar left the listener's; a form
;;;; evaluated from heml arriving at the listener's prompt, and an error from
;;;; one opening the docked debugger; the window closed and opened again with
;;;; its buffers; ⌘N still a listener; and heml put away at the end.

(in-package #:lisp-listener)

(defun heml-file-buffer (path)
  (find (namestring path) (symbol-value (find-symbol "*BUFFER-LIST*" "HEML"))
        :key (lambda (buffer)
               (let ((name (funcall (find-symbol "BUFFER-PATHNAME" "HEML") buffer)))
                 (and name (namestring name))))
        :test #'equal))

(defun heml-window ()
  (let ((display (symbol-value (find-symbol "*DISPLAY*" "HEML.COCOA"))))
    (and display (funcall (find-symbol "DISPLAY-WINDOW" "HEML.COCOA") display))))

(defun post-to-heml (item)
  (funcall (find-symbol "POST-TO-EDITOR" "HEML.COCOA") item))

(defun debugger-test-heml (listener directory)
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (file (merge-pathnames "heml-test.lisp" directory))
         (application (objc.runloop:shared-application))
         (delegate (objc:invoke application "delegate"))
         (menu (objc:invoke application "mainMenu")))
    (with-open-file (out file :direction :output :if-exists :supersede)
      (format out "(in-package :cl-user)~%~%(defun heml-made () (* 6 7))~%~%(defun heml-broken () (car 7))~%"))
    (check-step (and (menu-item-present-p "File" "Show Editor")
                     (menu-item-present-p "File" "Open in Editor…")
                     (menu-item-present-p "Listener" "Edit Definition"))
                "File > Show Editor, Open in Editor... and Listener > Edit Definition are there")
    ;; (ed "file") at the prompt, as a person types it.
    (type-and-submit listener (format nil "(ed ~s)" (namestring file)))
    (check-step (wait-for #'heml.cocoa:hosted-running-p :timeout 30)
                "(ed \"file\") at the prompt opens heml, in this application")
    (check-step (wait-for (lambda () (heml-file-buffer file)) :timeout 15)
                "visiting the file")
    (back-at-top-p listener)
    (check-step (and (live-pointer-p (heml-window))
                     (objc:invoke-bool (heml-window) "isVisible"))
                "its window is up")
    (check-step (cffi:pointer-eq (objc:invoke application "delegate") delegate)
                "and the application's delegate is still the listener's")
    (objc:invoke (objc:invoke (heml-window) "delegate") "windowDidResignKey:" nil)
    (check-step (cffi:pointer-eq (objc:invoke application "mainMenu") menu)
                "with heml's window not key, the menu bar is the listener's")
    ;; Evaluate Defun, in heml, on the first form: it is typed at the prompt.
    (post-to-heml (list :goto-line 3))
    (post-to-heml (list :command "Evaluate Defun"))
    (check-step (wait-for (lambda () (search "HEML-MADE" (transcript-text listener))) :timeout 15)
                "Evaluate Defun in heml evaluates the form at the listener's prompt")
    (back-at-top-p listener)
    (check-step (submit-and-wait listener "(heml-made)" "42")
                "and what it defined is there: (heml-made) is 42")
    (post-to-heml (list :goto-line 5))
    (post-to-heml (list :command "Evaluate Defun"))
    (wait-for (lambda () (search "HEML-BROKEN" (transcript-text listener))) :timeout 15)
    (check-step (raise-error listener "(heml-broken)")
                "a function from heml that signals opens the listener's debugger")
    (press-top-level-row listener)
    (back-at-top-p listener)
    ;; (ed 'name): where it is defined.
    (type-and-submit listener "(ed 'heml-made)")
    (check-step (wait-for (lambda () (heml-file-buffer file)) :timeout 15)
                "(ed 'name) opens the file it is defined in")
    (back-at-top-p listener)
    ;; Closed, it is put away, and the buffers live on.
    (objc:invoke (objc:invoke (heml-window) "delegate") "windowShouldClose:" (heml-window))
    (pump-for 0.3d0)
    (check-step (and (not (objc:invoke-bool (heml-window) "isVisible"))
                     (heml.cocoa:hosted-running-p))
                "closing heml's window hides it, and heml goes on")
    (check-step (press-menu-item "File" "Show Editor") "File > Show Editor")
    (pump-for 0.3d0)
    (check-step (and (objc:invoke-bool (heml-window) "isVisible") (heml-file-buffer file))
                "brings it back, with the file still in it")
    (write-window-png (heml-window)
                      (namestring (merge-pathnames "heml.png" directory)))
    (check-step (heml.cocoa:hosted-quit-ok-p) "with nothing changed, quitting is allowed")
    ;; Put away for good, and the listener as it was.
    (post-to-heml :quit)
    (check-step (wait-for (lambda () (not (heml.cocoa:hosted-running-p))) :timeout 15)
                "heml exits when it is told to")
    (pump-for 0.3d0)
    (check-step (cffi:pointer-eq (objc:invoke application "mainMenu") menu)
                "and the menu bar is the listener's")))
