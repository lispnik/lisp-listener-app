# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Lisp Listener in a native window: you type forms into a text view and the
values, the output and the debugger come back in the same transcript. **Two
front ends over one core**: AppKit (`NSTextView`) for SBCL on macOS, and UIKit
(`UITextView`) for ECL on iOS. Every Objective-C class in it is defined from Lisp through
[lispnik/objc](https://github.com/lispnik/objc); the Mac bundle is built by
[lispnik/asdf-macos-app](https://github.com/lispnik/asdf-macos-app) and the iOS
app by [lispnik/asdf-ios-app](https://github.com/lispnik/asdf-ios-app). One package
of code, `LISP-LISTENER` (and `CANVAS`, which holds only the names a person
types to draw); `OBJC` is deliberately not `:USE`d, because it exports `INVOKE`,
`RELEASE`, `RETAIN` and `DESCRIPTION` and this is the program where an accidental
capture of one of those is hardest to see.

**On the Mac it needs an SBCL built `--with-sb-safepoint`.** Darwin refuses to
`pthread_kill` a libdispatch workqueue thread, so `stop_the_world` calls `lose()`
and the process dies with no condition and no backtrace. AppKit reaches
libdispatch on its own account. The program starts on a stock build and says so
in the transcript rather than refusing. (ECL never signals a thread to collect,
so on iOS the question does not arise.)

## Build & test

```sh
ocicl setup         # once per machine
make deps           # ocicl install -- restores ./ocicl/ from ocicl.csv
make check          # all three off-macOS checks; the listener runs on SBCL and ECL
make run            # a listener from a REPL, on thread 1
make app            # => build/Lisp Listener.app
make demo           # => build/demo/lisp-listener-demo.mp4 (needs ffmpeg, ImageMagick)

make ios-toolchain  # once: asdf-ios-app builds the host and iOS ECLs (~10 min)
make ios            # => build/iphonesimulator/Lisp Listener.app
make run-ios        # build, install and launch in the booted simulator
make test-ios       # the self-test, in an iPhone simulator and an iPad one
make ios-demo       # => build/ios-demo/{iphone,ipad}/lisp-listener-ios-demo.mp4, from the self-test
make ios-device     # a signed development build for a phone (local.mk)
make testflight     # an App Store .ipa, checked, validated, uploaded (doc/testflight.md)
```

The iOS targets run under **ECL**, not SBCL: asdf-ios-app is ECL code and
cross-compiles with the ECL `ios-toolchain` built. The iOS app has a self-test:
`SIMCTL_CHILD_LISP_LISTENER_SELF_TEST=6 xcrun simctl launch <device>
org.lispnik.lisp-listener` drives a session, Tab, an error, the restarts sheet
and Cancel, an example, the canvas and a game of snake, holding N seconds on the screens worth photographing, and writes
`selftest: PASS` to `Documents/console.log` in the app's data container.
Take `xcrun simctl io` screenshots **in the same shell command as the launch**:
anything slower misses the holds.

The three checks run **anywhere, Linux included**, and that is the point — this
system cannot be *loaded* off macOS at all, because objc opens libobjc as it
initialises.

| target | question it answers |
|---|---|
| `make syntax-check` | does it parse? Reads every form with `*read-suppress*`. |
| `make compile-check` | does it compile? Builds the core plus **each** front end against `tools/stubs/`, one process per front end. |
| `make test` | **does the listener work?** On SBCL, with the Mac front end. |
| `make test-ecl` | the same, on ECL with the iOS front end. `make check` runs it when `ecl` is on the PATH. |

`make check` needs no dependencies at all — it runs against the stubs, so it
works in a fresh clone before `make deps`.

### The headless test is the unusual one

`tools/headless-test.lisp` runs a **real listener** on the stubs — real thread,
real gray streams, the real reader, evaluator, printer and debugger — and drives
it through a session, an error, `use-value`, `store-value`, `y-or-n-p` and an
abort, reading the transcript back and asserting on it. Only Cocoa is hollow.

It draws on the canvas and runs **every example** to its end (`case-canvas`,
`case-examples`): drawing only ever makes a list, so there is nothing to stub.

It also runs **two listeners at once** (`case-two-listeners`), which is the half
of New Listener that is not the window: two threads, two queues, two
transcripts, and the registry that decides which is which.

Two things make it possible, and both are load-bearing:

- `schedule-flush` (`src/streams.lisp`) declines to do anything while
  `*main-thread-target*` is NIL, so output piles up in the stream's own segments
  where the test reads it.
- `tools/stubs/stubs.lisp`'s `bordeaux-threads` is **not** a stub — it delegates
  to `sb-thread`, or to `mp` on ECL. Everything else in that file is a name with
  no behaviour.

ECL establishes no `USE-VALUE` or `STORE-VALUE` around an unbound variable, so on
ECL the test reaches one through `cl-user::missing-value`, which establishes
SBCL's three restarts in SBCL's order and then signals a real `unbound-variable`.

There is no CLI selector for one case; edit the `dolist` at the foot of the file,
or call one `case-*` function from a REPL after loading the stubs and `src/`.

**Build a verification for a change here before reaching for CI.** This harness
found, in seconds, a bug that three rounds of CI screenshots had not.

## Architecture

Two threads per listener, and the split is the whole design.

**Thread 1** owns AppKit or UIKit; on the Mac it ends in `-[NSApplication run]`,
and on iOS asdf-ios-app's `UIApplicationMain` owns it and calls `ios-start`,
which must return. Every message to a
view, a window or the text storage happens there. **The listener thread** is an
ordinary Lisp thread running read-eval-print and touches only Lisp state. So a
form that loops forever never freezes the window, and ⌘. gets the prompt back.

They meet at two queues: characters main → listener (the listener's
`*standard-input*` blocks on `src/queue.lisp`), and closures listener → main,
drained by an IMP that `-performSelectorOnMainThread:withObject:waitUntilDone:modes:`
delivers (`src/main-thread.lisp`).

**There can be more than one, and New Listener (⌘N) opens one.** `*listeners*`
is the live set; `*listener*` names whichever listener the code running now
speaks for and is **bound, never read as "the" listener**: `define-listener-method`
binds it from the view the IMP arrived on, `start-listener-thread` binds it in
each thread, and the restarts controller — one per listener — binds it from its
own slot. Anything reached from a menu item asks `current-listener` instead,
which is the key window's. A plain function that will be called from more than
one place resolves from its own argument (see `submit-input`) rather than
trusting the ambient value; the queue behind `*main-thread-target*` is shared
and global, so that one target is deliberately just "a view that is still
alive", repointed on close and never cleared.

Because `read` simply blocks on an incomplete form, **there is no Lisp parser in
the view**: Return always submits, and if the form is not finished no new prompt
appears. That falls out of the design rather than being arranged.

### Core and front ends

Three systems in `lisp-listener.asd`, each `:serial t`, and **the component
order is load-bearing**:

- `lisp-listener/core` — `src/`: `package impl main-thread queue listener history
  sexp paredit keymap indent transcript completion paren-highlight arglist paredit-view
  history-search streams config restarts preferences files canvas places views
  inspector standard-views objc-views examples repl`. No toolkit; SBCL and ECL.
- `lisp-listener` — the core plus `src/macos/`: `view window restarts-panel
  history-panel canvas-window preferences-window inspector-window screenshot
  objc-views debugger-test demo app`. The name it always had.
- `lisp-listener/ios` — the core plus `src/ios/`: `view restarts-sheet
  history-sheet canvas-sheet settings-sheet editor-sheet inspector-sheet
  objc-views app`.
- `lisp-listener/heml` — `lisp-listener` plus heml (`heml.cocoa`) and
  `src/macos/`: `heml heml-test heml-demo`. **The application depends on this one**
  (`lisp-listener-app.asd`); the library and `make run` do not, so the
  listener still loads with none of heml's dependencies (iolib and its
  libfixposix, osicat, prepl). asdf-macos-app bundles `libfixposix` and
  `libosicat` in `Contents/Frameworks`; the core is about 75 MB with heml.

`tools/compile-check.lisp` and `tools/headless-test.lisp` each carry the same
lists by hand; a new file has to be added in all three places. The core also
names `examples/*.lisp` as static files ahead of `examples`, which is what
makes ASDF compile it again when one changes.

**The seam is `src/impl.lisp`.** It is the only file in `src/` with `#+sbcl` or
`#+ecl` (debugger hook, backtrace, restart internals, exit, getenv). The one
exception is the Gray streams package, which `package.lisp` names with a local
nickname, `gray-streams`. `impl.lisp` also declaims what each front end must
define: `transcript-color`, `transcript-font`, `main-thread-run-loop-modes`,
`show-restarts-panel`, `hide-restarts-panel`, `restarts-panel-visible-p`,
`current-listener`, the canvas's five (`canvas-toolkit`, `show-canvas`,
`hide-canvas`, `canvas-visible-p`, `redisplay-canvas`, and `save-canvas-png`
and `documents-directory` for `(save …)`), the inspector's four
(`inspector-capabilities`, `show-inspector`, `refresh-inspector`,
`show-inspector-readout`), and the class
`listener-text-view`, with the same slots on
both. The core only ever touches that class through `-textStorage`,
`-selectedRange`, `-scrollRangeToVisible:` and `-typingAttributes`, which
NSTextView and UITextView share.

- `src/impl.lisp` — the seam, above.
- `src/listener.lisp` — the `listener` struct, holding both halves. **Nothing in
  it may be filled in at load time**: a foreign pointer does not survive
  `save-lisp-and-die` and the bundle is a dumped core.
- `src/transcript.lisp` — the transcript primitives over either text view, and
  the `define-listener-method` macro (every IMP wrapped in `handler-case`).
- `src/sexp.lisp` — the sexp scanner, **copied from `revl`** (lispnik's own MIT
  editor) and renamed: paren matching and the structural edits, over a string and
  a character offset. Every scan asks `skip-non-code` first, so they all agree on
  what is not code: `;` comments, strings, nested `#|…|#`, `|symbols|` (spaces
  and parens included), `#\(` and `\(`. `[` and `{` are constituents, as in
  standard syntax. The two copies are now separate.
- `src/paredit.lisp` — the commands, each `(text offset) → (values text offset)`
  or NIL to decline. Balanced insertion is written here; the structural ones wrap
  `apply-structural-edit`. Pure, so `make test` covers all of it.
- `src/keymap.lisp` — `*paredit-enabled*`, `*paren-highlight-enabled*`,
  `*auto-indent-enabled*` and `*paredit-keys*`, an alist of key spec (`"("`, `"C-)"`, `"C-M-f"`,
  `"Backspace"`) to command. `(setf (paredit-key "C-(") 'slurp-backward)` rebinds;
  a command not in `*paredit-commands*` is refused.
- `src/indent.lisp` — `newline-and-indent`, a command of the same shape: a body
  form two in, a call under its first argument, anything else one in. Whether an
  operator takes a body is asked of the live image (`&body` in the macro's lambda
  list, through `macro-lambda-list` in `impl.lisp`), with a table for special
  operators and Emacs's `def…` rule. Option-Return on both front ends: AppKit
  already sends it to `-insertNewlineIgnoringFieldEditor:`, and iOS has a
  `UIKeyCommand`. Plain Return still submits.
- `src/paredit-view.lisp` — the one place a command meets a view: character
  offsets to UTF-16 units, the read-only guard, the write-back. It also binds the
  prompt's width for the indenter: the input's first line starts after
  `CL-USER> `, so its columns are not its offsets.
- `src/paren-highlight.lisp` — the tint under the caret's paren and its partner,
  red when it has none. Input region only.
- `src/arglist.lisp` — the hint: the lambda list of the innermost call around
  the caret (`call-at`, which walks outward past a list that is no call, and
  sees no call inside a string or comment), and which argument the caret is on
  (`lambda-list-argument`; nothing past `&key`). Pure, `(text offset package)`,
  so `make test` covers it. Printed without escapes, so without the
  implementation's package prefixes. Lambda lists come from the live image,
  from `*special-operator-arglists*`, and on iOS from `*recorded-arglists*`:
  ECL reads CL's lambda lists from a help file at run time, which the app is
  built without, so `recorded-cl-arglists` (`impl.lisp`) asks the compiling
  ECL and compiles the answers in. `refresh-arglist-hint` runs on every
  selection change and calls the front end's `show-arglist-hint` only when
  something changed: the window's subtitle on the Mac (plain text, so the
  argument is bracketed ‹ ›), a line over the key bar on iOS (attributed,
  bold). `*arglist-hints-enabled*` is the `:arglist-hints` preference.
- `src/config.lisp` — `init.lisp`, read from `history-directory` at startup, so a
  rebinding survives a launch. A broken one is reported, never fatal.
  `init-file-path` is where it is; the exported `(init-file)` makes it from
  `*init-file-template*` if it is missing, and is what Settings opens: Edit
  init.lisp… on the Mac (`open-init-file`: NSWorkspace, then TextEdit), and an
  editor sheet on iOS (`src/ios/settings-sheet.lisp`) whose Save and Load
  types `(load "…")` at the prompt.
- `src/history-search.lisp` — the history picker: ⌘R lists everything submitted,
  typing narrows it (every whitespace-separated term must appear, ignoring case),
  ↓ goes from the field into the list and ↑ from its top row back,
  and a chosen row goes into the input region **unsubmitted**. The filtering is
  pure; the list is `src/macos/history-panel.lisp` (a **sheet** on the listener
  window -- an `NSSearchField` over an `NSTableView`, begun with
  `-beginSheet:completionHandler:` and ended by `hide-history-popup`) or `src/ios/history-sheet.lisp` (a sheet
  with a `UISearchBar`), behind `show-history-popup` / `hide-history-popup` /
  `history-popup-visible-p`.
- `src/completion.lisp` — symbol completion, from the listener's package, which
  `emit-prompt` publishes in the `listener-package` slot because thread 1 cannot
  see the thread's `*package*`. It also has `complete-at-caret`, the shell-style
  completion (insert, extend, or list) for a toolkit with no popup.
- `src/streams.lisp` — the gray streams, and the segment buffer that coalesces a
  thousand `write-char`s into one hop to the main thread.
- `src/restarts.lisp` — what the restarts panel does, on either platform: the
  titles, which restart Cancel means, and the hop to put them up and take them down.
- `src/files.lisp` — File ▸ Open… and a file dropped on the window both load by
  typing `(load "…")` at the prompt (`load-files-into-listener`), so the
  transcript records it, an error opens the debugger, and the line goes into
  the history; nothing is loaded on thread 1. Save Transcript… is
  `save-transcript`. The panels are `src/macos/app.lisp`'s, the drop is the
  view's `-performDragOperation:`, which leaves anything not Lisp to the text
  view. `(download url)` is here too: Foundation's
  `-dataWithContentsOfURL:` on the listener thread, into the front end's
  `download-directory` (`~/Downloads`; the app's folder on iOS). Both tests use
  a `file://` URL, so neither needs the network.
- `src/preferences.lisp` — the settings a window can change, and what the
  application remembers for itself (where its windows were), in one plist,
  `preferences.lisp-expr`, beside the history: read with `*read-eval*` off,
  loaded **before** `init.lisp`, which therefore wins. `(setf (preference
  :font-size) 16)` sets the variable, applies it and saves. Not
  NSUserDefaults: this is one mechanism on both platforms, `make test` covers
  it, and a driven run -- whose history directory is its own -- starts from
  the defaults without being told.
- `src/canvas.lisp` — a canvas to draw on from the prompt, and the `CANVAS`
  package's functions (`line`, `circle`, `forward`, `frame`, `key`...), which
  `install-user-vocabulary` imports into `CL-USER` when the first listener
  starts. 200 units square, origin in the middle, y up. **Drawing is on the
  listener thread and only pushes onto a display list**; thread 1's
  `-drawRect:` paints it, after one coalesced hop that declines with no
  `*main-thread-target*` -- the same seam as `schedule-flush`, so `make test`
  draws and reads the list back. `(frame ...)` swaps in a whole picture, which
  is animation. The **painter is here, for both toolkits** (`paint-canvas`):
  both views are flipped, `canvas-device-ops` turns y over and gathers
  neighbouring lines into one path, and `canvas-toolkit` picks between the
  three selectors NSBezierPath and UIBezierPath disagree on. `(pointer)` is
  the mouse or a finger, reported by the front end in the view's coordinates
  (`canvas-pointer-event`) and a press is also the key `:click`. `(save
  "x.svg")` writes the display list out, all here; `(save "x.png")` is the
  front end's `save-canvas-png`, on thread 1, waited for.
  **The turtle is painted over the drawing, not into it**: its commands keep
  `*turtle-sprite*` (where it is, and the line it is part way along) and
  `paint-canvas` appends `turtle-sprite-ops` to the display list it paints,
  so `canvas-contents`, SVG and a saved PNG (`*canvas-paint-turtle*`, bound
  NIL by `save`) are the drawing alone; it shows once a turtle command runs
  after `clear`, and never in a frame. `(turtle-speed n)` -- not `speed`,
  which CL-USER inherits from CL -- walks and turns in steps of
  `*turtle-frame-seconds*` through `wait`, so a test's time scale of 0 makes
  watching free. `(filled ...)` collects the turtle's points and puts a
  `:polygon` UNDER what was drawn since it began (`canvas-add-beneath`), and
  `(stamp)` adds one; `:polygon` is a shape like the others, in both painters
  and in SVG.
- **The inspector**, five files, all toolkit-free. The names a contributor
  types are a third package, `INSPECTOR`, defined from inside `LISP-LISTENER`
  as `CANVAS` is, and **not** imported into `CL-USER` (`text` is the canvas's).
  - `src/places.lisp` — a `place` is where a value is: it answers its value,
    whether it has one, what may be done to it (`:set`, `:remove`) and whether
    a given value is acceptable. Clouseau's idea; it is what makes an edit a
    property of the row and not of the table. Adding a NEW thing is the
    collection's business, not a place's: `inspector:addition` says what an
    object takes (`:value`, `:key-and-value`) and `inspector:add` does it --
    a list is added to at its END, destructively, so that it stays the list
    being inspected. Taking one out or putting one in the MIDDLE is a place's
    (`place-remove`, `place-insert`, `:remove` and `:insert`): a vector that
    can grow, and a list through `list-element-place`, which works on the
    conses in place -- removing the first element copies the second cons into
    the first, so the list is the same object afterwards, and that is why the
    ONLY element of a list cannot be removed. `inspector:objc` wraps a foreign
    pointer somebody vouches for as an Objective-C object (`objc-object`);
    nothing ever sends a message to a bare pointer.
  - `src/views.lisp` — `inspector:define-view` registers a view by type, an
    optional `:when` predicate and a priority; `applicable-views` sorts by
    priority, then the more specific type. **A view draws nothing**: it
    answers a scene (`table`, `text`, `drawing`, `stack`, `section`), which is
    data. A `drawing`'s body calls the canvas's functions with
    `*canvas-frame*` bound, so they collect into a list. Options are declared
    data, the view's own; `define-controls` contributes controls bound to
    places, which belong to the object. A drawing may carry a `:readout`, a
    function of a point answering what to say about it. `:objc-class "NSImage"`
    matches by `-isKindOfClass:` instead of a type; `:requires (:appkit)`
    keeps a view from applying where the front end lacks that capability;
    `inspector:native` is a scene that is a function answering a toolkit view,
    with a fallback scene for text and for the other platform.
    `view-applicability` answers why a view does NOT apply, which is what the
    Mac's All Views sheet shows. The time limit lives here too
    (`with-time-limit`, `*inspector-time-limit*`), because `view-scene` is its
    first user.
  - `src/inspector.lisp` — the session (object, path, two panes, per-object
    state) and the **worker thread**: a view is somebody's code, thread 1
    never evaluates, and the listener thread is busy, so scenes are computed
    and places written on a third thread and handed to thread 1 as a MODEL of
    strings and shapes. With no `*main-thread-target*` a job runs where it is
    asked for, which is the seam `make test` uses. `(inspect x)` is redirected
    through `with-inspect-hook` (`impl.lisp`), and prints the model as text
    where `inspector-capabilities` is empty -- the stubs, with no main thread.
    A **watchdog** thread interrupts the worker when a view, a row or a
    control's action has run past the limit; the interrupt carries a token, so
    one sent for a piece of work that has just finished cannot land on the
    next. An **Objective-C object** is computed on thread 1 instead
    (`call-in-object-thread`, waited for) and is not timed: thread 1 is not
    for interrupting. The inspector retains every such object it walks into
    and releases them when it closes. `readout-shapes` makes a readout's
    crosshair and label out of the canvas's own shapes, so both painters draw
    it. `stop-inspector-worker` ends the worker by a `:stop` job, never an
    interrupt -- see "Interrupt needs two mechanisms".
  - `src/standard-views.lisp` — the views that ship, written with
    `define-view` and nothing else. Disassembly applies only where
    `function-disassembly` (`impl.lisp`) answers: ECL's would run a C compiler.
  - `src/objc-views.lisp` — Foundation's objects: any object, `NSArray`,
    `NSDictionary`, `NSString`. What comes out of a collection is wrapped on
    the way, so it can be walked into. The toolkit's own are
    `src/macos/objc-views.lisp` (an image, a view's and a window's picture,
    a window's opacity and title) and `src/ios/objc-views.lisp` (a `UIImage`).
- `src/examples.lisp` — `(examples)`, `(example "snake")`,
  `(example-source "snake")`, and `(example-edit "snake")`, which puts the
  source at the prompt. The fifteen programs are `examples/*.lisp`, **read
  into the image as strings when this file is compiled** (`embedded-examples`):
  an app has no source tree beside it. Run by reading and evaluating each form
  in `CL-USER` on the listener thread; the Examples menu and the Try key only
  type `(example "…")` at the prompt. A new one is a file, a name in
  `*example-names*`, and a static file in `lisp-listener.asd`.
- `src/repl.lisp` — the listener thread, the debugger and the backtrace. Each
  frame is captured with its locals (`backtrace-frame`), printed on the listener
  thread while the stack exists; SBCL only, since ECL's frame stack keeps
  neither arguments nor locals, and a value is capped at `*local-value-length*`.
  The run of the implementation's own evaluator at the bottom
  (`internal-frame-p`, by package) is trimmed when anything is left above it,
  and cut to its innermost frame when nothing is. While the pane or sheet is up
  (`restarts-pane-offered-p`) the transcript prints the restarts as one line of
  numbers and names and leaves the frames to the pane.
- `src/macos/view.lisp` — `LispListenerView` over `NSTextView`: Return, the
  arrows, and Tab through NSTextView's own completion popup.
- `src/macos/restarts-panel.lisp` — the debugger, **docked**: the listener
  window's content is an `NSSplitView`, and while a debugger level is open a
  pane sits under the transcript -- the heading, the frames as an
  `NSOutlineView` whose rows open to their locals, an `NSTableView` of whatever
  `compute-restarts` returned, and Cancel and Invoke. The divider moves;
  `layout-restarts-panel` places everything again on each
  `NSViewFrameDidChangeNotification`, since the heading's height depends on how
  its report wraps. The rows and heading arrive as
  `restart-row`s and a `debugger-heading` from `src/restarts.lisp`, printed on the
  listener thread; the row past the listener's own top-level restart (SBCL's
  per-thread abort) is relabelled "Abort the listener thread" in the panel and
  the transcript alike. It opens on the top-level row, not row 0. ⌘0–⌘9 choose
  a row from the listener window (`-performKeyEquivalent:` on the view, since
  the panel never takes the keyboard). A restart that asks for a value
  (USE-VALUE, STORE-VALUE) asks **in the panel**: a field opens, and Return
  types `1 42` at the prompt — the debugger reads a number followed by a form
  as that restart with that value (`restart-selection`). Every choice is
  typed through the view by `type-into-listener`, so the transcript shows it,
  whatever was half-typed is put back, and the history is not touched. The
  field's room comes from the transcript: the divider moves up while it is
  open. Frames and locals carry their full text as a tooltip.
- `src/macos/canvas-window.lisp` — the canvas as a window: one for the
  application, made on first use beside the front listener, closed with the
  last listener. Drawing brings it forward but **leaves the keyboard at the
  prompt**; `(show)` is what makes it key, and a game calls it. `-keyDown:`
  feeds `(key)`, the mouse methods feed `(pointer)` -- `-mouseMoved:` too,
  which wants an `NSTrackingArea`, active always since the window is usually
  not key -- and `-acceptsFirstMouse:` is true so the click that wakes the
  window also lands.
- `src/macos/preferences-window.lisp` — Settings… (⌘,): five checkboxes and a
  pop-up of sizes over `src/preferences.lisp`, each in force at once. Closed
  with the last listener, like the canvas. `src/macos/window.lisp` has the
  other half of that file's job: `remember-windows` (as a window closes, and
  at `-applicationWillTerminate:`) and `restore-windows` (from `main` only).
- `src/macos/inspector-window.lisp` — the inspector's window: a path bar, two
  panes (a pop-up of views, a row of controls made from the view's options,
  and a drawing, a cell-based table and text sharing the room), and the object
  panel (what it is, the selected row and a field to change it, the
  contributed controls, the views and who contributed each). The selection is
  a row AND the column clicked (`-clickedColumn`), since in a grid every cell
  is a place; a row's cells carry their own editable and removable flags,
  computed on the worker. It shows the model and evaluates nothing; every action is a request whose answer is a
  new model. The drawing is painted by `paint-shapes`, the canvas's painter.
  Controls are told new values rather than rebuilt while their set is
  unchanged -- a slider rebuilt mid-drag is a slider let go of. The drawing
  has a tracking area: `-mouseMoved:` asks the worker for a readout and
  `show-inspector-readout` paints it, unless the pointer has left meanwhile.
  A native scene's view is made by its function on each refresh and put in the
  pane's `:native-host`. **All Views…** is a sheet on the inspector's window
  whose table's data source is the window's controller: every view, greyed
  with its reason where it does not apply, and Show in Left/Right Pane.
- `src/ios/inspector-sheet.lisp` — the inspector on iOS: a sheet at full
  height, ONE pane and one inspector at a time (a second `(inspect x)` takes
  the sheet over). A segmented control of views, the options and contributed
  controls as rows, the scene's drawing, native view, table and text sharing a
  stack, and at the foot the selected row's field with Open, Set, Insert,
  Remove and Add (`inspector-add-line`: one field, so a hash table's entry is
  a key and then a value). **Views** in the header presents a second sheet
  listing every view, with why each that does not apply does not; its table
  shares the controller and is told apart by its tag. Every control's target is the sheet's one
  controller, by tag -- `uikit:on-tap` keeps its target for good, and these
  are rebuilt.
- `src/macos/heml.lisp` — heml in this application. heml (lispnik/heml) has a
  **hosted mode** for this: `heml.cocoa:start-hosted` on thread 1 opens it in
  a running NSApplication without running or stopping it, leaving the
  application's delegate alone, swapping heml's menu bar in only while its
  window is key, and hiding rather than quitting when its window closes.
  `heml:*evaluate-text-function*` is set to `heml-evaluate-text`, which hops
  to thread 1 and types the text at the frontmost listener's prompt, after
  `(in-package …)` when heml's buffer package differs; heml calls it on its
  own thread. `listener-ed-function` goes first on `sb-ext:*ed-functions*`,
  ahead of heml's own (which assumes it owns the main thread), and finds a
  symbol's file and line with sb-introspect. `*editor-menu-items*`
  (`src/macos/window.lisp`) is how it adds to the File and Listener menus,
  so the menus have no items for an editor that is not there.
  `-applicationShouldTerminate:` asks `heml.cocoa:hosted-quit-ok-p`.
- `src/macos/heml-test.lisp` — the driver's heml section, run by
  `run-debugger-test` when the image has it: `(ed "file")`, the delegate and
  menu bar left alone, Evaluate Defun reaching the prompt, an error from it
  opening the debugger, `(ed 'name)`, close and Show Editor, quit. heml's own
  test of the hosted mode is `make smoke-hosted` in heml.
- `src/macos/heml-demo.lisp` — the demo's editor scene, which `run-demo` plays
  when the image has it (`make demo` loads `lisp-listener/heml`): `(ed
  "greet.lisp")`, an edit typed into heml, Evaluate Defun redefining at the
  prompt the `greet` the demo defined there, and the new one called. heml's
  window goes over the top of the listener's and is composited in through
  `*demo-overlays*`.
- `src/ios/editor-sheet.lisp` and `src/editor.lisp` — the iOS editor. The
  editor is a `listener-text-view` whose `role` is `:editor` and whose input
  region starts at 0, so paredit, the indenter, completion, the paren tint and
  the hints work on the whole buffer unchanged; Return indents, the arrows are
  lines, and no output arrives. `listener-for-view-object` answers the
  editor's listener, and completion, hints and indentation read in the file's
  package (`view-reading-package`, from the last `(in-package …)` before the
  caret, read with `*read-eval*` off in a scratch package). Eval types the
  form at the caret with `type-into-listener`, after `(in-package …)` when the
  packages differ, and shows what the transcript said once the listener is at
  a prompt again. One editor, kept; the file is saved on Close and on Open….
- `src/macos/screenshot.lisp` — drives a real listener and photographs it; this is what
  produces `doc/screenshots/`, on a CI runner, on every push.
- `src/macos/demo.lisp` — `LISP_LISTENER_DEMO=<dir>` plays a scripted session a
  key at a time and photographs each step; `tools/make-demo.sh` makes the
  captioned video, and `make demo` does both. A sheet is a window of its own, so
  it is composited in -- under the title bar, where a sheet hangs, not where its
  frame says -- and so is the canvas, which the demo parks over the listener's
  lower right corner. An inspector's window is laid over the listener the same
  way, with its All Views sheet composited into IT first, since a sheet is
  placed against the window it hangs from. A table scrolled in a window that
  is not key is photographed with its header drawn over its rows, so the
  scene chooses rows already in sight. `doc/inspector-more.png` is two of its
  frames; `doc/ios-inspector.png` is three iPhone screenshots from the
  self-test. `tools/make-gif.sh` cuts the README's `doc/canvas.gif`
  out of the video by caption. The turtle's scene (`demo-turtle`) watches the
  flower drawn -- `*canvas-time-scale*` slows it so the photographs keep up,
  and each frame is shown for its time over that scale -- then draws the
  L-systems, saving each without the turtle into `turtle/`, which `make demo`
  makes into `build/demo/turtle-gallery.png`; `doc/turtle-gallery.png` is a
  copy, and `doc/turtle.png` one of the flower's frames. CI makes it only on Run workflow
  (`workflow_dispatch`), arm64.
- `src/macos/debugger-test.lisp` — `LISP_LISTENER_DEBUGGER_TEST=<dir>` drives the
  docked debugger through what a person does with it and checks each step:
  docking, frames and locals, the keys, the divider, the value field, Escape,
  a second level, the history sheet, a second listener beside the first,
  File ▸ Open…, a dropped file and Save Transcript…, the Examples menu and the
  canvas (its keys, its mouse, saving it), Settings and the View menu, the
  remembered windows, and the inspector (its window, options, navigation, an
  edit, contributed controls, each of the four ways of opening one, a readout,
  the All Views sheet, Insert and Remove in a list, and Objective-C objects:
  a pointer vouched for, an `NSArray` walked into, a window's picture and its
  opacity slider).
  Exits 0 only if every check held; `macos.yml` runs it on
  both architectures. **Everything in the pane is AppKit, so the headless test
  reaches none of it**; every bug in the pane's first versions was found by
  this driver and by nothing else. Run it locally with
  `LISP_LISTENER_DEBUGGER_TEST=/tmp/dt sbcl --eval '(asdf:load-system "lisp-listener")' --eval '(lisp-listener:main)'`.
- `src/ios/view.lisp` — `LispListenerView` over `UITextView`: Return through the
  delegate, `UIKeyCommand`s for Tab, ↑, ↓, Esc, ⌘., ⌘K and ⌘0–⌘9 (a restart,
  while the sheet is up), and a key bar with the same keys above the on-screen
  keyboard.
- `src/ios/restarts-sheet.lisp` — the restarts as a sheet, each row the report
  over its number and name (the subtitle cell style): a `UIViewController`
  with a `UITableView` whose data source is the same `restarts-controller` the
  Mac's table uses, presented at `UISheetPresentationController`'s medium
  detent and draggable to full height. A restart that asks for a value asks
  in a `UITextField` under the heading, hidden until then; Return sends
  `1 42`, as on the Mac. A second section lists the frames, by name only.
- `src/ios/canvas-sheet.lisp` — the canvas's panel: Done, the view, and a row
  of arrow buttons that are the keys `(key)` answers (buttons, not swipes: a
  sheet already has a meaning for a vertical drag). **Docked** beside the
  transcript where the window is at least 700 points wide -- an iPad -- by
  switching the transcript's trailing constraint (`*transcript-trailing*`) for
  one to the panel; otherwise a **sheet** at the medium detent, presented
  without animation so that the restarts can go over it at once. A
  zero-length `UILongPressGestureRecognizer` is the finger for `(pointer)`:
  it begins the instant a touch lands, so the sheet's own pan never sees a
  stroke drawn downwards. `save-canvas-png` paints into a
  `UIGraphicsImageRenderer` through a block. `replace-canvas` moves a canvas
  that is up between the two when the width crosses the line; the transcript's
  `-layoutSubviews` is what notices (`note-canvas-room`), and the move is
  scheduled for the next pass of the run loop, never made inside the layout.
- `src/ios/settings-sheet.lisp` — Settings, from the ⚙ key or ⌘,: a `UISwitch`
  per switch and a `UIStepper` for the size, each through `(setf preference)`.
  Built afresh on each show, so it says what is in force.
- `src/ios/app.lisp` — `ios-start`, the self-test, and `open-url`: `.lisp` is
  the app's document type (`lisp-listener-ios.asd`), asdf-ios-app's scene
  delegate hands a URL from Files to `ios-app-runtime:*open-url-hook*`, and the
  hook copies the file in if it is not the app's own (`import-opened-file`, in
  `src/files.lisp`) and types `(load "…")`. `UIFileSharingEnabled` with
  `LSSupportsOpeningDocumentsInPlace` puts the app's Documents in the Files app.
  `show-open-picker` (the Open key, ⌘O) is the same from inside: a
  `UIDocumentPickerViewController`, opening in place, with the copy made while
  the security scope is held.

`lisp-alien.png` is the icon's source art, and `res/` is what the two builders
take: `res/icon.png`, the alien inset in a rounded rectangle, which
asdf-macos-app turns into an `.icns`; and `res/LispListener.xcassets`, whose
icon is full-bleed, 1024x1024 and **without an alpha channel** -- iOS requires
both, and rounds the corners itself. Rebuilt with ImageMagick from the source
art; neither file is generated by the build.

The bundles are separate `.asd` files, `lisp-listener-app.asd` and
`lisp-listener-ios.asd`, and they must stay separate: `:defsystem-depends-on` is
resolved when a `.asd` is **read**, not when its system is built, so declaring
either bundle in `lisp-listener.asd` would make its builder a hard requirement
for anyone who only wants to load the library.

## CI

`ios.yml` cross-compiles the iOS app with ECL -- asdf-ios-app checked out
beside this repository at its master and ahead of everything else on the
registry, its cross-built ECLs cached by ECL commit, build script and patches
-- and runs `tools/ios-selftest.sh` in an iPhone and an iPad simulator.

`check.yml` runs the three checks on Linux in seconds. `macos.yml` builds SBCL
`--with-sb-safepoint` (cached, pinned to a tag), verifies the build really has
them, runs the self-test, builds and runs the bundle, proves the ocicl-only path,
and takes the screenshots — on **arm64 and Intel**. On a `v*` tag each leg also
zips the app it built and ran (`ditto`, which keeps the signature) and attaches
it to that tag's release; the app is signed ad hoc, and the release notes say
how to get past Gatekeeper. On Run workflow (`workflow_dispatch`), and on a tag,
the arm64 leg also makes the demo video -- on a tag it goes on the release,
which is what the README's video link points at -- last, with Homebrew's `ffmpeg-full` -- the plain
`ffmpeg` formula has no libass and so no captions. The Intel leg is not
box-ticking: a struct over sixteen bytes returns through `objc_msgSend_stret` on
x86-64 and through `x8` on arm64, and every `NSRange` and `NSRect` here crosses
that boundary.

`ocicl.csv` pins the whole closure by digest, `objc` and `asdf-macos-app`
included, so a fresh clone needs no sibling checkouts. CI nevertheless checks
both out and puts them **ahead of `ocicl/`** on `CL_SOURCE_REGISTRY`, so the
checkout shadows the published copy — this repository is meant to break when
objc's `master` breaks. ASDF takes the first match, so that ordering is the
entire mechanism.

## Things that are easy to get wrong

Each of these is a bug that actually happened here.

- **`run-listener` must not use a modal session.** It used
  `-[NSApplication runModalForWindow:]`, which blocks events to every OTHER
  window of the application — so New Listener opened a window you could see and
  not type in; an ordinary second window gets no events during a modal
  session. It is
  `-[NSApplication run]` now, stopped by `stop-run-loop-soon` when the last
  window closes.

- **`-[NSApplication stop:]` needs an event behind it.** It raises a flag that
  `-run` tests after finishing the event in hand and then asking for the NEXT
  one. Closing the last window is very often the last event there is, so
  without `post-wakeup-event` the loop sits blocked with the flag set and the
  REPL never comes back.

- **`applicationShouldTerminateAfterLastWindowClosed:` must answer NIL in a REPL
  session.** `-terminate:` exits the process, and under `run-listener` that
  process is somebody's SBCL: answering T killed the REPL instead of returning
  to it, and did it before `run-listener`'s own unwinding had run. It keys off
  `*stop-run-loop-on-last-close*`, which is bound — soundly, because the IMP
  runs on thread 1 inside the `-run` that `run-listener` is blocked in.

- **Never clear `*main-thread-target*` while a listener thread may still
  write.** A closing listener is still unwinding and still printing, and with a
  NIL target each write signals inside the debugger hook, which aborts, which
  loops. It span 204 times in the space of one close. `retarget-main-thread`
  only ever repoints it; the old view stays a valid receiver because
  `-releasedWhenClosed` is off and closing deallocates nothing.

- **`unwind-protect` around `listener-loop`, never `handler-case`.** A handler for
  `error` established out there *handles* the condition, and a handled condition
  never reaches `invoke-debugger` — so `*debugger-hook*` does not run and an
  error in an evaluated form quietly restarts the listener. This function had
  exactly that shape; **the entire debugger was dead code and nothing said so**,
  until the first CI screenshot that reached it.

- **Bind both `cl:*debugger-hook*` and `sb-ext:*invoke-debugger-hook*`** (ECL:
  `ext:`), **and bind them again at every debugger level.** `invoke-debugger`
  nulls whichever hook it calls while it runs, so each level down uses one up:
  with the two bound once, level 3 fell through to the Lisp's own debugger.
  `listener-debugger` rebinds both from `*listener-debugger-hook*`.

- **An error evaluated at a debugger prompt must be sent to `invoke-debugger`
  by hand.** All of `listener-debugger` runs inside the hook's `handler-case`,
  which would otherwise handle it. That is the same trap as `handler-case` around
  `listener-loop`, one level down: every error typed at `[1]` silently returned
  to `CL-USER>`, and no level below the first ever opened. The `handler-bind`
  around the debugger's evaluation does this; `case-nested-debugger` covers it.

- **`fresh-line` on a two-way stream asks the INPUT half for its column.** So
  `listener-input-stream` needs a `stream-line-column` method although it
  implements no output protocol. Without it every `~&` on `*query-io*` signalled
  `no-applicable-method`, which took out `invoke-restart-interactively` entirely
  — `use-value` and `store-value` could not be used at all — and left `y-or-n-p`
  printing its question and never receiving the answer. It looks like dead code.
  It is not; `make test` has three cases on it.

- **Find the top-level restart by OBJECT, never by index.** On an unbound
  variable — the commonest error there is — SBCL puts `continue`, `use-value` and
  `store-value` in front of the listener's own `abort`, which sits at **index 3**.
  Index 0 there is `Retry using *FOO*`, which retries, and retries. `make test`
  and the macOS workflow both assert the index is not 0.

- **Escape needs two selectors, and the conventional one is not the one that
  works.** Escape is `-cancelOperation:` in most controls, but inside an
  `NSTextView` the standard key bindings send it to `-complete:`. Overriding only
  `-cancelOperation:` looks correct and does nothing. The reverse holds for Tab:
  it calls **super's** `-complete:`, because the view's own override cancels a
  debugger level first.

- **Compute the restarts panel's labels on the LISTENER thread.** A restart's
  report may read the *current* thread rather than the one it was established on;
  SBCL's per-thread abort restart does exactly that, via
  `sb-thread:*current-thread*` at print time. Printed from thread 1 while laying
  out the panel it named the main thread and was quietly wrong.

- **Insert output AT `input-start`, not at the end.** Otherwise a `format` from a
  computation still running is spliced into the middle of the line being typed.

- **Reset the output stream's column after `read`.** The view already appended
  the newline the user pressed, but the stream last wrote the prompt and still
  believes it is nine columns in — so `fresh-line` emits a newline that is
  already on screen and every value gets a blank line above it.

- **Start a backtrace from `sb-debug:*stack-top-hint*`, not `:from
  :debugger-frame`.** Outside SBCL's own debugger, `:debugger-frame` falls back
  to the most recent *interrupted* frame on the stack, and at a second debugger
  level the first error's trap (an unbound variable, say) is still down there:
  every level-2 backtrace was level 1's. And bind the hint to NIL around what is
  evaluated at a debugger prompt (`with-fresh-stack-top`), or `error` there
  inherits level 1's frame. `case-nested-backtrace` covers both; two calls to
  `error` pass without either fix, so it errors on an unbound variable first.

- **ECL's frame stack holds a closure's CODE, not the closure.** So an
  anonymous debugger hook could be found neither by name nor by `eq`, and ECL's
  cut after `invoke-debugger` -- which is not on its frame stack at all -- cut
  nothing: every ECL backtrace began with `BACKTRACE-FRAMES` and the listener's
  own debugger. The hook is the named function `listener-debugger-hook`, and
  ECL's frames are cut at its name.

- **The debugger's `read-line` needs the column reset too.** The fix for a
  blank line above every value was made in `listener-rep`, and the debugger
  reads its own lines, so everything evaluated at `[1]` had one.
  `case-no-blank-line` checks both places.

- **A key equivalent sent to an inactive process reaches nothing.**
  `-[NSApplication sendEvent:]` gives ⌘-keys to the key window, and an SBCL
  started from a terminal is not the active application, so it has none. A
  driver has to call the window's `-performKeyEquivalent:` and then the main
  menu's, which is the order AppKit uses. Menu actions that ask
  `current-listener` do nothing there for the same reason.

- **A button's key equivalent beats the text view to the key.** Docked in the
  listener window, Invoke's Return would have been pressed by every Return typed
  at `[1]`. The pane's buttons have no key equivalents; Escape reaches the text
  view's `-complete:` as always, ⌘0–⌘9 come through `-performKeyEquivalent:`, and
  the table and the outline `setRefusesFirstResponder:` so a click leaves the
  keyboard at the prompt. (That setting governs clicks only;
  `-makeFirstResponder:` still obeys, so test it with `-acceptsFirstResponder`.)

- **Set a lone table column's width outright.** `-sizeLastColumnToFit` left the
  outline's column at its default hundred points, and every frame came out as
  `0: (SIMPLE…`. The restart table escaped only because its column was made at
  a width near the right one.

- **asdf-ios-app must trap ECL's interrupt signal.** Its `ECLBoot.m` switched
  off ECL's handlers for the fault signals -- they fight iOS and the debugger --
  and `ECL_OPT_TRAP_INTERRUPT_SIGNAL` went off in the same block. That one is not
  a fault: it is the signal ECL sends its own thread to run an interrupt, and
  untrapped the interrupt is simply lost. So `(loop)` typed on a phone could not
  be stopped, on any thread, and this file said so and blamed ECL. The iOS
  self-test now types `(loop)` and presses Stop, last, and fails with the option
  off.

- **Interrupt needs two mechanisms, and the choice must be made under the
  queue's lock.** An interrupt that aborts does not reliably unwind a thread out
  of a condition wait: on ECL it does not unwind it at all -- the abort is lost
  -- and it leaves the lock held-but-not-owned, so the next unlock signals
  `Attempted to give up lock ... that is not owned by process'. So a thread
  parked in `read` is asked through the queue's flag and aborts itself as it
  wakes, and only a thread off in a computation is interrupted.
  `queue-request-abort-if-waiting` answers under the lock, which is what makes
  the choice exact; a flag set while the thread was computing would otherwise
  be left for a later read to trip over, and clearing it at the prompt lost a
  Stop pressed in the gap between a value and its prompt. `case-interrupt`
  covers both states, and it took a fifteen-run hammer to see the race.

- **An UNMATCHED paren must be deletable, and `or` loses the offset.** Backspace
  first refused every paren, which left a character that could only be removed
  by clearing the line -- the unmatched one is the one that is wrong, and
  deleting it is the fix. `delete-paren-p` asks `paren-match-offset` and refuses
  only a matched one. Forward Delete goes by the same rule and is a **different
  key**: `#\Rubout`, not `#\Backspace`, and on iOS the two are told apart by
  whether the affected range starts at the caret or one before it. Both commands
  return two values, so they cannot be written with `OR` -- it keeps only the
  first, and the caret went to NIL.

- **`show-history-popup` takes the old list down, so "forgetting" must not drop
  the rows.** `forget-history-popup` cleared the controller's rows as well as the
  panel, and since showing hides first, it emptied the list
  `open-history-popup` had just filled: the table came up with nothing in it.
  Stale rows are harmless — the next open replaces them.

- **An example changed is not an app rebuilt.** The examples are strings read
  in when `src/examples.lisp` is compiled. ASDF is told -- they are static
  files ahead of it in `lisp-listener.asd` -- and SBCL's builds follow; but
  asdf-ios-app's cross-compile goes by the `.lisp` files alone, and the iOS
  self-test found yesterday's spiral in today's app. The Makefile's
  `src/examples.lisp: examples/*.lisp` rule touches the file, and every target
  that builds depends on it.

- **A file that launches the app arrives before the first prompt.** The scene
  delegate delivers a launch URL the moment `ios-start` returns, when the
  listener thread has printed half a banner: typed then, the load came out as
  `ECL(load "…") 26.5.5`. `load-when-prompted` waits on a timer for the first
  prompt to be on screen. And **the copy must be made in the hook**, not then:
  a document's URL is security scoped, readable only until the hook returns.

- **A table offers its arrow keys to nobody.** NSTableView handles them in
  `-keyDown:` itself -- no delegate, no `doCommandBySelector:` -- so ↑ from the
  top of the history list back to the search field needed a subclass,
  `history-table-view`, whose `-keyDown:` takes that one case and gives every
  other key to super.

- **A table's data source must never answer a nil cell, even for a row that
  has gone.** The restarts are withdrawn the moment one is chosen, and the
  sheet is still animating away with its table on screen. An iPhone does not
  ask again; an iPad's focus engine walks the table during the dismissal, got
  nil for a row counted earlier, and UITableView's assertion killed the app.
  Only the iPad simulator showed it. `make-blank-cell` is the answer for any
  row the controller no longer has.

- **A driven run stalls for minutes when the display is asleep.** Sheets and
  window ordering wait on a display that is not there: the debugger test took
  fifteen minutes instead of fifty seconds, with the stall in a different
  place each time, and looked exactly like a hang in whatever had just been
  changed. Run it under `caffeinate -d -u` when nobody is at the machine. (A
  CI runner's display never sleeps.)

- **Two filled boxes that meet on the canvas must meet on the screen.** Scaled
  and left where they fell, each edge was antialiased on its own and a grid of
  boxes had a hairline between every row -- the Mandelbrot set looked ruled.
  `canvas-device-ops` puts a filled rectangle's EDGES on whole points and
  takes its size from them.

- **The demo cannot photograph a game at the speed it is played.** A frame is
  two window captures and a composite, which is longer than a turn of Snake;
  turns went by unseen and the scripted keys, keyed to turn numbers, were
  never pressed. `*canvas-time-scale*` slows the game five times,
  `*canvas-frames*` says when there is a new picture, and a key that was due
  is pressed late rather than never.

- **A presentation that does not take says nothing, and nothing asks again.**
  UIKit will not present over a sheet still on its way out, and a sheet
  dismissed without animation is still not gone until the run loop has turned.
  Choose an example from the Try list and press Return quickly, and the canvas
  was asked for while the list was leaving: no canvas, and the drawing was
  finished, so no further redisplay came to try again. One self-test run in
  several. `present-canvas-sheet` looks afterwards and tries again a quarter
  of a second later, twelve times; `replace-canvas` leaves a canvas docked
  while its old sheet is still up.

- **The start of the line is after the prompt.** C-a put the caret at the left
  margin, in front of `CL-USER> `, where nothing can be typed. On the Mac C-a
  is `-moveToBeginningOfParagraph:`, not `-moveToBeginningOfLine:` (that is
  Home and ⌘←, with `-moveToLeftEndOfLine:`), and each has an
  `…AndModifySelection:` twin for Shift: six selectors, all overridden, and
  only for the input's first line -- every other line starts at the margin
  and is super's. iOS claims C-a and ⌘← as key commands, and having claimed
  them must do the whole job (`move-to-input-line-start`).

- **A printed value is a link, and a link is repainted.** Values in the
  transcript carry `NSLinkAttributeName` so that a click opens the inspector
  (`print-values` writes each as kind `(:value id)`; `transcript-insert` adds
  the link). A text view left to itself draws a link blue and underlined: the
  Mac view's `linkTextAttributes` are set to a pointing-hand cursor and
  nothing else. On iOS the mark is an attribute of our own
  (`add-value-link` is the front end's): an editable UITextView does not
  follow links and still paints them blue -- which is what every value looked
  like in the one build that added `NSLinkAttributeName` there. A tap is a
  `UITapGestureRecognizer` beside the text view's own, with a delegate that is
  NOT the view (a UITextView is the delegate of its own scroll pan), and it
  counts only if the view already had the keyboard: the tap that brings the
  keyboard up lands anywhere. The values are KEPT so that they can be
  opened -- the last 500 a listener printed, until the transcript is cleared.

- **UIKit will neither present nor dismiss during a transition, and says so
  only in the log.** A dismissal asked for while the sheet is arriving is
  dropped; a presentation asked for over a sheet that is leaving is put off,
  or lands on the leaving sheet and goes with it; and
  `-dismissViewControllerAnimated:` sent to a sheet with another on top
  dismisses the one on top. Each left a sheet up that the program had already
  forgotten: the Try list, opened as the restarts went, stayed for good -- on
  the iPad to the end of the self-test, which passed regardless. Every sheet
  now comes through `present-sheet` and goes through
  `dismiss-sheet-when-settled` (`src/ios/restarts-sheet.lisp`): both ask
  again every 0.15 s until the way is clear (`settled-presenter`), a
  dismissal goes through the PRESENTER, hiding a sheet not yet presented
  cancels the presenting, and a transition is told by
  `-transitionCoordinator` -- NOT `-isBeingPresented`, which is true only
  inside the appearance callbacks. The canvas's controller is kept and shown
  again, so showing it calls `cancel-sheet-dismissal`. The self-test checks
  that nothing is left presented after the Try list.

- **A table on its way out must keep its data source.** Setting it to nil
  "so it asks nobody" is the iPad crash again: the focus engine walks a table
  during its dismissal, and a promised row with no cell is an assertion in
  UITableView. It only showed once dismissals could be delayed. The
  inspector sheet's controller outlives the sheet (the last four are held in
  `*retired-sheet-controllers*`, because a table holds its data source
  weakly) and answers a blank cell for a row it no longer has.

- **ASDF on iOS is ECL's own, linked in** (`:bundle-ecl-modules ("asdf")` in
  `lisp-listener-ios.asd`; asdf-ios-app builds it for the device). Home is the
  app's Documents folder, so ASDF's default source registry finds
  `Documents/common-lisp/` and its output cache is `Documents/.cache/`.
  `compile-file` there is the bytecodes compiler, which asdf-ios-app installs
  at boot, and writes `.fasc` files. The self-test writes a two-file system
  into `common-lisp/hello-asdf/` and loads it. `getenv` in `impl.lisp` still
  does not use UIOP, as UIOP is not there before ASDF is.

- **ECL's `inspect` answers its argument.** SBCL's answers nothing. So on iOS
  `(inspect bytes)` opened the inspector and then printed all 256 bytes under
  the prompt. `inspect-object` notes what it was called on in `*inspected*`,
  bound per evaluation, and `evaluate-for-values` leaves out a lone value that
  is that object. It is a MACRO: as a function it was a frame between the
  listener and `eval`, and the backtrace trimming failed its test.

- **A path's label is printed when the model is made, not when the step is
  taken.** The root's label was the object as it printed when the inspector
  opened, and went on saying `(:A :B)` after the list had changed. Front ends
  must therefore not use the labels to tell whether the inspector has moved:
  `model-steps` and `same-steps-p` are for that.

- **ECL will not quit past a thread parked in a condition wait.** The
  inspector's worker waits for jobs that way, and once `make test-ecl` had
  started one, the test printed its verdict and then never exited. The worker
  is ended by a job it takes, `:stop`, and the headless test asks for that
  before it leaves.

- **A stack view has to be told which arranged view takes the slack.** The iOS
  inspector's content -- a drawing, a table -- had the default hugging
  priority like everything else in the sheet, and with a scene that wanted no
  height of its own (a picture) UIKit stretched the header instead: the title
  sat in the middle of the sheet over a star twenty points across. The content
  stack's vertical hugging priority is 1, and a native view's own are too.

- **UIKit presents only from the top of the stack.** Asked to present from a
  controller that is already presenting, it logs a warning and does nothing: an
  error in a form that had just drawn, with the canvas's sheet up, would have
  put no restarts on screen at all. `presenting-controller` walks
  `presentedViewController` to the top, skipping one that `isBeingDismissed`.

- **A canvas the person closed must stay closed until the next form.** Drawing
  shows the canvas, and an animation draws sixty times: closed at frame ten it
  came straight back at frame eleven. `canvas-closed-by-person` sets
  `*canvas-dismissed*` (and pushes Escape, so a game ends), and the REPL clears
  it before each evaluation (`canvas-evaluation-begins`), at the top level and
  at a debugger prompt alike. The flag is tested **twice**: where the redisplay
  is asked for, and again in the hop on thread 1 -- a hop already queued when
  the window closed reopened it, one run in several, and only CI's arm64 leg
  lost that race.

- **In a driven run every menu item answers NO to `-isEnabled`.** The process
  is not the active application, and once the menu bar has been handed a key
  equivalent in that state its items all read disabled -- while ⌘K goes on
  being taken. `-performActionForItemAtIndex:` declines a disabled item and
  says nothing, so the driver's `press-menu-item` sends the item's action to
  its target itself. It is the driver's condition, not the application's.

- **A character typed beside a tinted paren INHERITS the tint**, because a text
  view takes its typing attributes from the character at the insertion point.
  Those indices are not in the marks list, so clearing by remembered range left
  them coloured: typing `(room` coloured `room`, and submitting carried the
  colour up into the read-only transcript for good.
  `clear-paren-highlight` therefore sweeps `NSBackgroundColorAttributeName` off
  the **whole input region**, and both front ends reset the typing attributes as
  the caret moves. NOT the whole transcript, which it once did: an attribute
  changed over all of the storage on every keystroke made UIKit lay the whole
  transcript out again, and with the caret on the bottom line the view jumped
  by screenfuls while typing -- 3,213 points back up over 31 keys, measured by
  the iOS self-test, which now samples the offset every 10 ms while it types. `submit-input` and `transcript-insert` clear before they
  touch the text, while the ranges still mean something.

- **The paren tint has to be re-applied, not preserved.** `replace-pending-input`
  and `replace-token` both reset the whole attribute dictionary over the input
  with `-setAttributes:range:`, and arriving output shifts every index, so both
  call `refresh-paren-highlight` afterwards and `transcript-insert` drops the
  marks. Trying to keep a highlight alive across an edit is wrong about half the
  time.

- **On iOS, `-insertText:` called programmatically does not consult the
  delegate.** So it walks straight past the paredit hook in
  `-textView:shouldChangeTextInRange:replacementText:`, and a self-test that
  typed with it reported that `(` did not auto-close when in fact it does.
  UIKit's own contract is to ask the delegate and insert only on true, which is
  what `type-into-view` now does.

- **macOS chords need `-keyDown:`; everything else does not.** `C-)`, `M-(` and
  `C-M-f` are bound to no standard selector, so they arrive nowhere else. The
  override claims only what the keymap has and calls super otherwise, which is
  what keeps Return, Tab, the arrows and Escape arriving at their own IMPs
  through `-interpretKeyEvents:`. Self-inserting characters belong in
  `-insertText:replacementRange:` instead, the only hook that sees which
  character it is.

- **Output inserted at the caret must carry the caret along.** NSTextView
  moves a caret that sits at the insertion point; UITextView leaves it behind,
  in front of the output. `transcript-insert` moves it only if the toolkit did
  not, so the one code path is right on both.

- **On iOS, Return is not `-insertNewline:`.** It arrives as the delegate being
  asked whether `"\n"` may replace a range, through
  `-textView:shouldChangeTextInRange:replacementText:`. AppKit's selector ends in
  `replacementString:`, and defining that name on iOS does nothing.

- **UIKit resets the typing attributes whenever the selection moves**, so
  `-textViewDidChangeSelection:` puts them back. **A text view keeps Tab and the
  arrows for itself** unless each `UIKeyCommand` sets
  `wantsPriorityOverSystemBehavior`.

- **A `UIAlertController` cannot be made taller.** It is sized by its content,
  with no supported way to ask for more room, so the restarts came up as a stub
  at the foot of the screen. A presented controller with **detents** is what
  has a height of its own; that is why the sheet is one.

- **There is no `NSModalPanelRunLoopMode` on iOS.** That is why the run loop
  modes belong to the front end.

- **`NSInteger` is `(:signed :long-long)`.** `'l'`/`'L'` are 32 bits even on
  LP64; `NSInteger` encodes as `'q'`.

- **An `NSRange` arrives as a CONS** `(location . length)`. Other Cocoa structs
  arrive as vectors.

- **An object returned from a Lisp method is the caller's to release.** The table
  delegate's row views are autoreleased for that reason — AppKit asks again on
  every redraw, and a +1 object there leaks one per row per repaint.

- **Name run-loop modes individually**, never `kCFRunLoopCommonModes`, when
  hopping to the main thread.

- **`macos-26-intel`, never `macos-13`.** The old free Intel image is retired and
  a job labelled with it is never assigned a runner: it queues indefinitely
  rather than failing, so the workflow never reports at all. This is the most
  expensive mistake available in the workflow, because it looks like a slow queue.

- **The screenshots are compared only if nothing in them varies by chance.**
  `debugger.png` and `restarts.png` were once left out of the comparison: the
  restart list ended with SBCL's per-thread abort restart, whose report prints a
  fresh `tid`. That row is relabelled now, and `debugger.png` is taken with the
  pane switched off (`*restarts-panel-enabled*`, SETF'd -- the listener thread
  reads it), because the pane arrives a hop after the transcript and a picture
  taken in between had it or not. Taken locally, all four still differ from run
  to run if you are using the machine: a window that happens to be key draws
  coloured traffic lights and a caret.

- **A driven run must not write the person's history.** The screenshots, the
  debugger test, the demo and the self-test submit lines like anyone, and the
  history is kept between launches: every local run of the debugger test left
  its forms in `~/Library/Application Support/Lisp Listener/`, and the demo's ⌘R
  list showed a page of them. `isolate-driven-history` points
  `*history-directory*` into the run's own output when any of them is on.

- **Write CI scratch files to `$RUNNER_TEMP`,** and screenshots too. Writing them
  under `doc/screenshots/` makes `test -s` pass against the *committed* files and
  the check proves nothing.
