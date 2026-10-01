;;;; lisp-listener-ios.asd -- the Lisp Listener as an iOS app, built by
;;;; asdf-ios-app with ECL.
;;;;
;;;;     make ios            ; => build/iphonesimulator/Lisp Listener.app
;;;;     make run-ios        ; build, install and launch in the booted simulator
;;;;
;;;; SEPARATE FROM lisp-listener.asd for the reason lisp-listener-app.asd is:
;;;; :DEFSYSTEM-DEPENDS-ON is resolved when a .asd is READ, so the bundle here
;;;; would make asdf-ios-app a requirement for loading the library at all.
;;;;
;;;; Built with ECL, not SBCL -- asdf-ios-app cross-compiles with the host ECL
;;;; that (asdf-ios-app:bootstrap-ecl) builds, which is what `make ios-toolchain'
;;;; runs.  The simulator is the default; a device is built for only when the
;;;; environment says how to sign for one, and nobody's identity is committed.
;;;; LISP_LISTENER_DISTRIBUTION=1 is an App Store build -- `make ipa', and
;;;; doc/testflight.md -- for the device alone and without get-task-allow,
;;;; which App Store Connect refuses.

(defsystem "lisp-listener-ios"
  :defsystem-depends-on ("asdf-ios-app")
  :class :ios-app-system
  :build-operation "ios-app-op"
  :entry-point "lisp-listener:ios-start"
  :description "A Lisp Listener in a UITextView: the REPL, the debugger and its restarts, on the phone."
  ;; The build number, which every upload must raise: `make ipa' sets it from
  ;; the commit count.
  :version #.(or (uiop:getenv "LISP_LISTENER_BUILD") "0.1.0")
  :bundle-short-version "0.1.0"
  :depends-on ("lisp-listener/ios")

  :bundle-identifier "org.lispnik.lisp-listener"
  :bundle-name "Lisp Listener"
  :bundle-executable "lisp-listener"
  :bundle-platforms #.(cond ((uiop:getenv "LISP_LISTENER_DISTRIBUTION") '(:device))
                            ((uiop:getenv "IOS_SIGNING_IDENTITY") '(:simulator :device))
                            (t '(:simulator)))
  :get-task-allow #.(not (uiop:getenv "LISP_LISTENER_DISTRIBUTION"))
  ;; Lisp source is this app's document: Files and a share sheet offer the
  ;; listener for a .lisp file, and opening one loads it (OPEN-URL).  The type
  ;; is declared below because the system has none for Lisp.
  :bundle-document-types
  ((:dict ("CFBundleTypeName" . "Lisp source")
          ("CFBundleTypeRole" . "Editor")
          ("LSHandlerRank" . "Owner")
          ("LSItemContentTypes" . (:array "org.lispnik.lisp-source"))))
  :bundle-info-plist
  (;; Export compliance, answered: the listener encrypts nothing.
   ("ITSAppUsesNonExemptEncryption" . :false)
   ;; These two together put the app's Documents in the Files app, under On
   ;; My iPhone: a file dropped there is one (load "name.lisp") away, and the
   ;; history and console.log can be got at.  Opening in place also means a
   ;; file from elsewhere arrives as itself, not as a copy in an Inbox.
   ("UIFileSharingEnabled" . :true)
   ("LSSupportsOpeningDocumentsInPlace" . :true)
   ("UTExportedTypeDeclarations"
    . (:array (:dict ("UTTypeIdentifier" . "org.lispnik.lisp-source")
                     ("UTTypeDescription" . "Lisp source")
                     ("UTTypeConformsTo" . (:array "public.source-code" "public.plain-text"))
                     ("UTTypeTagSpecification"
                      . (:dict ("public.filename-extension"
                                . (:array "lisp" "lsp" "cl" "asd"))))))))
  ;; All four: an app that runs on an iPad must, for multitasking, and App
  ;; Store Connect refuses a bundle without upside-down portrait (90474).
  :bundle-orientations (:portrait :portrait-upside-down :landscape-left :landscape-right)
  ;; An asset catalogue, compiled by actool.  Its icon is 1024x1024 and has no
  ;; alpha channel, both of which iOS requires.
  :bundle-icon "res/LispListener.xcassets"
  :code-signing-identity #.(or (uiop:getenv "IOS_SIGNING_IDENTITY") :automatic)
  :development-team #.(uiop:getenv "IOS_DEVELOPMENT_TEAM")
  :provisioning-profile #.(uiop:getenv "IOS_PROVISIONING_PROFILE"))
