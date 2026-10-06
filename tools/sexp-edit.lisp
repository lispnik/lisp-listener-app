;;;; tools/sexp-edit.lisp -- load vendor/sexp-edit for the off-macOS checks.
;;;;
;;;; The listener's structural editing is lispnik/sexp-edit, a submodule.  It is
;;;; real code with no dependencies, not something to stub, so compile-check and
;;;; headless-test load it as it is -- by LOAD rather than through ASDF, which
;;;; would read whatever source registry the machine has.  The order is
;;;; vendor/sexp-edit/sexp-edit.asd's, which is :SERIAL; tests/cases.lisp is the
;;;; corpus of edits headless-test replays through the listener's own glue.

(in-package #:cl-user)

(let ((directory (merge-pathnames "vendor/sexp-edit/" *root*)))
  (unless (probe-file (merge-pathnames "sexp-edit.asd" directory))
    (format t "~&~a is empty: run git submodule update --init~%" directory)
    #+sbcl (sb-ext:exit :code 2) #+ecl (ext:quit 2))
  (dolist (name '("src/package" "src/sexp" "src/paredit" "src/keymap" "src/indent"
                  "tests/cases"))
    (load (merge-pathnames (format nil "~a.lisp" name) directory)
          :external-format :utf-8)))
