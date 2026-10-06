# Lisp Listener.
#
# `check' runs anywhere, including on Linux with no Objective-C runtime.
# Everything below it wants macOS, and an SBCL built --with-sb-safepoint.

SBCL ?= sbcl

# Signing, which is personal: local.mk, never committed.  See doc/testflight.md.
-include local.mk

.PHONY: deps check syntax-check compile-check test test-ecl run app demo ios-demo \
        ios-device ipa testflight \
        ios-toolchain ios run-ios test-ios clean

ECL ?= ecl

## Restore the dependencies this project pins, into ./ocicl/.
##
## ocicl.csv is a LOCKFILE: it names each dependency by its registry digest,
## not by a version that can be re-cut, so this restores the same sources on
## every machine and every run.  It covers objc and asdf-macos-app as well, so
## a fresh clone needs no sibling checkouts -- see the README.
##
## sexp-edit, the structural editing heml shares, is a submodule instead.
##
## Needs the ocicl tool itself: https://github.com/ocicl/ocicl
deps:
	git submodule update --init
	ocicl install

## All three off-macOS checks.  The first two cannot tell you the program
## works; the third can, for everything that is not a window.  With ECL on the
## PATH the third runs twice, once on each Lisp the listener ships on.
check: syntax-check compile-check test
	@if command -v $(ECL) >/dev/null 2>&1; then $(MAKE) --no-print-directory test-ecl; \
	 else echo "check: no $(ECL) on the PATH, so the ECL half of the test is skipped"; fi

## Does it parse?  Reads every form with *READ-SUPPRESS*; needs nothing at all.
syntax-check:
	$(SBCL) --script tools/syntax-check.lisp

## Does it compile?  Builds src/ against tools/stubs/, so the compiler can
## report undefined functions, wrong argument counts and macros that will not
## expand -- none of which a parse check can see.
compile-check:
	$(SBCL) --script tools/compile-check.lisp macos
	$(SBCL) --script tools/compile-check.lisp ios

## Does it WORK?  Runs a real listener on the stubs -- real thread, real
## streams, real reader, evaluator and debugger -- and drives it through a
## session, the debugger, the interactive restarts, Y-OR-N-P and abort.  Only
## Cocoa is hollow, so the window, the panel and the table are untested here.
test:
	$(SBCL) --script tools/headless-test.lisp

## The same listener on ECL, the Lisp an iOS app runs: the core and the iOS
## front end on the stubs.  A stock ECL is enough; this needs no iOS toolchain.
test-ecl:
	$(ECL) --norc --load tools/headless-test.lisp

## A listener from a REPL, on thread 1.  Needs objc on the source registry.
run: src/examples.lisp
	$(SBCL) --eval '(asdf:load-system "lisp-listener")' \
	        --eval '(lisp-listener:run-listener)' --quit

## Build the bundle.  Run this with the SAFEPOINT SBCL: asdf-macos-app copies
## the runtime of whichever SBCL performs the build, so a stock one here pairs
## a stock runtime with this core and gives back the very fragility the
## safepoint build exists to remove.
app: src/examples.lisp
	$(SBCL) --eval '(asdf:make "lisp-listener-app")' --quit

## A captioned video of a session in the real window, typed a key at a time:
## build/demo/lisp-listener-demo.mp4.  Needs ffmpeg (with libass) and
## ImageMagick; see src/macos/demo.lisp and tools/make-demo.sh.  With heml, so
## that the editor is in it (src/macos/heml-demo.lisp).  The turtle's pictures
## are saved as it goes, and made into build/demo/turtle-gallery.png.
demo:
	rm -rf build/demo
	LISP_LISTENER_DEMO=$(CURDIR)/build/demo $(SBCL) --non-interactive \
	    --eval '(require :asdf)' \
	    --eval '(asdf:load-system "lisp-listener/heml")' --eval '(lisp-listener:main)'
	tools/make-demo.sh build/demo
	cd build/demo/turtle && magick \( dragon.png snowflake.png hilbert.png -resize 400x400 +append \) \
	    \( arrowhead.png plant.png rosette.png -resize 400x400 +append \) -append ../turtle-gallery.png

## The examples are read into the image when src/examples.lisp is COMPILED.
## ASDF knows that -- lisp-listener.asd names them as static files -- but
## asdf-ios-app's cross-compile goes by the .lisp files alone, and built an app
## with the spiral of the day before.  So every target that builds one depends
## on this, which makes the file newer than the examples it holds.
src/examples.lisp: $(wildcard examples/*.lisp)
	touch $@

## The iOS app.  ios-toolchain builds, once, the host and simulator ECLs that
## asdf-ios-app cross-compiles with (about ten minutes); set
## IOS_SIGNING_IDENTITY to build for a device as well.  asdf-ios-app is itself
## ECL code, so these run under ECL, not SBCL.
IOS_REGISTRY = CL_SOURCE_REGISTRY="$(CURDIR)//:$(CL_SOURCE_REGISTRY)"

ios-toolchain:
	$(IOS_REGISTRY) $(ECL) --norc --eval '(require :asdf)' \
	    --eval '(asdf:load-system "asdf-ios-app")' \
	    --eval '(asdf-ios-app:bootstrap-ecl)' --eval '(ext:quit 0)'

ios: src/examples.lisp
	$(IOS_REGISTRY) $(ECL) --norc --eval '(require :asdf)' \
	    --eval '(asdf:make "lisp-listener-ios")' --eval '(ext:quit 0)'

## Needs a booted simulator: open -a Simulator.
run-ios: src/examples.lisp
	$(IOS_REGISTRY) $(ECL) --norc --eval '(require :asdf)' \
	    --eval '(asdf:load-system "asdf-ios-app")' \
	    --eval '(princ (asdf-ios-app:run-in-simulator "lisp-listener-ios"))' \
	    --eval '(ext:quit 0)'

## The app's self-test, in an iPhone simulator AND an iPad one: the iPad is not
## a big phone, and has shown a crash the iPhone never did.  DEVICES names
## others.  tools/ios-selftest.sh has the rest.
test-ios: ios
	tools/ios-selftest.sh $(DEVICES)

## iOS on a phone.  `ios-device' builds a development app for a connected
## device (IOS_SIGNING_IDENTITY and IOS_PROVISIONING_PROFILE in local.mk);
## `ipa' an App Store build, packaged; `testflight' checks, validates and
## uploads it.  doc/testflight.md has the one-time steps.
BUILD ?= 0.1.$(shell git rev-list --count HEAD)
IPA = build/Lisp-Listener.ipa
IOS_ECL = $(IOS_REGISTRY) $(ECL) --norc --eval '(require :asdf)' \
	--eval '(handler-bind ((serious-condition (lambda (c) (format *error-output* "~&error: ~a~%" c) (ext:quit 1)))) (asdf:load-system "asdf-ios-app"))'

ios-device: src/examples.lisp
	@test -n "$(IOS_SIGNING_IDENTITY)" -a -n "$(IOS_PROVISIONING_PROFILE)" || { echo "error: set IOS_SIGNING_IDENTITY and IOS_PROVISIONING_PROFILE in local.mk" >&2; exit 1; }
	IOS_SIGNING_IDENTITY="$(IOS_SIGNING_IDENTITY)" IOS_PROVISIONING_PROFILE="$(IOS_PROVISIONING_PROFILE)" \
	IOS_DEVELOPMENT_TEAM="$(IOS_DEVELOPMENT_TEAM)" $(IOS_ECL) \
	    --eval '(print (uiop:symbol-call :asdf-ios-app "MAKE-APP" "lisp-listener-ios" :platforms (list :device)))' \
	    --eval '(ext:quit 0)'

# From a clean build/iphoneos: a stale bundle can lack the compiled icon, and
# App Store Connect then refuses it for a missing CFBundleIconName.
ipa: src/examples.lisp
	@test -n "$(IOS_DISTRIBUTION_IDENTITY)" -a -n "$(IOS_DISTRIBUTION_PROFILE)" || { echo "error: set IOS_DISTRIBUTION_IDENTITY and IOS_DISTRIBUTION_PROFILE in local.mk" >&2; exit 1; }
	rm -rf build/iphoneos "$(IPA)"
	LISP_LISTENER_DISTRIBUTION=1 LISP_LISTENER_BUILD="$(BUILD)" \
	IOS_SIGNING_IDENTITY="$(IOS_DISTRIBUTION_IDENTITY)" \
	IOS_PROVISIONING_PROFILE="$(IOS_DISTRIBUTION_PROFILE)" \
	IOS_DEVELOPMENT_TEAM="$(IOS_DEVELOPMENT_TEAM)" $(IOS_ECL) \
	    --eval '(uiop:symbol-call :asdf-ios-app "EXPORT-IPA" (first (uiop:symbol-call :asdf-ios-app "MAKE-APP" "lisp-listener-ios" :platforms (list :device))) :output (merge-pathnames "$(IPA)" (uiop:getcwd)))' \
	    --eval '(ext:quit 0)'

testflight: ipa
	ASC_KEY_ID="$(ASC_KEY_ID)" ASC_ISSUER_ID="$(ASC_ISSUER_ID)" tools/testflight.sh "$(IPA)"

## The iOS app's self-test, recorded and captioned step by step, in an iPhone
## simulator and an iPad one -- where the canvas docks beside the transcript:
## build/ios-demo/{iphone,ipad}/lisp-listener-ios-demo.mp4.
ios-demo: ios
	DEVICE=iPhone tools/ios-demo.sh build/ios-demo/iphone
	DEVICE=iPad tools/ios-demo.sh build/ios-demo/ipad

clean:
	rm -rf build
	find . -name '*.fasl' -delete
