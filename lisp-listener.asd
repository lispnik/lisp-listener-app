;;;; lisp-listener.asd -- a Lisp Listener in a Cocoa window, or a UIKit one.
;;;;
;;;; Three systems.  LISP-LISTENER/CORE is everything that is not a toolkit --
;;;; the listener thread, the queues, the streams, the debugger, the transcript
;;;; over a text view's storage -- and runs on SBCL and on ECL.  LISP-LISTENER
;;;; is the core plus the AppKit front end, and keeps the name it always had.
;;;; LISP-LISTENER/IOS is the core plus the UIKit front end, for ECL on iOS.
;;;;
;;;; Component order is load-bearing within each, and tools/compile-check.lisp
;;;; and tools/headless-test.lisp carry the same lists by hand.
;;;;
;;;; The .app bundle is a SEPARATE system in lisp-listener-app.asd, on purpose:
;;;; :DEFSYSTEM-DEPENDS-ON is resolved when a .asd file is READ, not when the
;;;; system it belongs to is built, so declaring the bundle here would make
;;;; asdf-macos-app a hard requirement for anyone who only wants to load the
;;;; library.  utc-status-app carries the bug report that taught this.

(defsystem "lisp-listener/core"
  :description "The Lisp Listener's toolkit-free half, for SBCL and ECL."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("objc" "bordeaux-threads")
  :components ((:module "src"
                :serial t
                :components
                ((:file "package")
                 (:file "impl")
                 (:file "main-thread")
                 (:file "queue")
                 (:file "listener")
                 (:file "history")
                 (:file "sexp")
                 (:file "paredit")
                 (:file "keymap")
                 (:file "indent")
                 (:file "transcript")
                 (:file "completion")
                 (:file "paren-highlight")
                 (:file "arglist")
                 (:file "editor")
                 (:file "paredit-view")
                 (:file "history-search")
                 (:file "streams")
                 (:file "config")
                 (:file "restarts")
                 (:file "preferences")
                 (:file "files")
                 (:file "canvas")
                 (:file "places")
                 (:file "views")
                 (:file "inspector")
                 (:file "standard-views")
                 (:file "objc-views")
                 ;; Read into the image when "examples" is compiled; named here
                 ;; so that changing one compiles it again.
                 (:static-file "hello" :pathname "../examples/hello.lisp")
                 (:static-file "spiral" :pathname "../examples/spiral.lisp")
                 (:static-file "turtle" :pathname "../examples/turtle.lisp")
                 (:static-file "lsystem" :pathname "../examples/lsystem.lisp")
                 (:static-file "rose" :pathname "../examples/rose.lisp")
                 (:static-file "tree" :pathname "../examples/tree.lisp")
                 (:static-file "life" :pathname "../examples/life.lisp")
                 (:static-file "snake" :pathname "../examples/snake.lisp")
                 (:static-file "sierpinski" :pathname "../examples/sierpinski.lisp")
                 (:static-file "mandelbrot" :pathname "../examples/mandelbrot.lisp")
                 (:static-file "clock" :pathname "../examples/clock.lisp")
                 (:static-file "ball" :pathname "../examples/ball.lisp")
                 (:static-file "doodle" :pathname "../examples/doodle.lisp")
                 (:static-file "pong" :pathname "../examples/pong.lisp")
                 (:static-file "thermal" :pathname "../examples/thermal.lisp")
                 (:file "examples")
                 (:file "repl")))))

(defsystem "lisp-listener"
  :description "A Lisp Listener in a native Cocoa window, for SBCL on macOS."
  :long-description
  "A read-eval-print loop living in an NSTextView: you type forms into the
window and the values, the output and the debugger come back in it.  Cocoa runs
on thread 1 and the listener runs on an ordinary SBCL thread; they meet at two
queues, so a long computation never freezes the window.

Every Objective-C class here is defined from Lisp through lispnik/objc.  Needs
an SBCL built --with-sb-safepoint; see the README for why."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :license "MIT"
  :version "0.1.0"
  :homepage "https://github.com/lispnik/lisp-listener-app"
  :source-control (:git "https://github.com/lispnik/lisp-listener-app.git")
  :depends-on ("lisp-listener/core")
  :components ((:module "src/macos"
                :pathname "src/macos/"
                :serial t
                :components
                ((:file "view")
                 (:file "window")
                 (:file "restarts-panel")
                 (:file "history-panel")
                 (:file "canvas-window")
                 (:file "preferences-window")
                 (:file "inspector-window")
                 (:file "screenshot")
                 (:file "objc-views")
                 (:file "debugger-test")
                 (:file "demo")
                 (:file "app")))))

(defsystem "lisp-listener/heml"
  :description "The Lisp Listener with heml, the editor, in its application."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :license "MIT"
  :version "0.1.0"
  ;; heml's own, with what it needs: iolib (and libfixposix), osicat, prepl.
  ;; A system of its own so that loading the listener does not need any of it.
  :depends-on ("lisp-listener" "heml.cocoa")
  :components ((:module "src/macos"
                :pathname "src/macos/"
                :serial t
                :components ((:file "heml")
                             (:file "heml-test")
                             (:file "heml-demo")))))

(defsystem "lisp-listener/ios"
  :description "The Lisp Listener in a UITextView, for ECL on iOS."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("lisp-listener/core" "objc/uikit")
  :components ((:module "src/ios"
                :pathname "src/ios/"
                :serial t
                :components
                ((:file "view")
                 (:file "restarts-sheet")
                 (:file "history-sheet")
                 (:file "canvas-sheet")
                 (:file "settings-sheet")
                 (:file "editor-sheet")
                 (:file "inspector-sheet")
                 (:file "objc-views")
                 (:file "app")))))
