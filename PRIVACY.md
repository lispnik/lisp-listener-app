# Privacy

Lisp Listener collects nothing.

That is the whole policy, and it is true because of how the program is made
rather than because of a promise: neither the Mac application nor the iOS app
sends anything anywhere on its own account. There are no accounts, no
analytics, no advertising, no crash reporting of its own, and no third-party
libraries that do any of those things. The source is in this repository; you
can check.

## What stays on your device

Everything you type is evaluated on your own device, by a Common Lisp running
inside the application. Nothing typed, evaluated, printed or drawn is sent
anywhere.

The application keeps a few files for itself, all on your device:

- **Your history** — the forms you have submitted, so that ↑ and history search
  work between launches.
- **Your settings** — the switches in Settings, the size of the type, and, on
  the Mac, where the windows were.
- **`init.lisp`**, if you write one.
- **Pictures you save** from the canvas with `(save …)`.
- **Copies of files you open** from another app on iOS, in a folder called
  `Opened`, so that they can be loaded again.
- **Files you edit** in the editor, and on iOS its `scratch.lisp`.
- **Files you fetch** with `(download …)`.

On the Mac these are in `~/Library/Application Support/Lisp Listener/`, with
saved pictures in `~/Pictures/` and fetched files in `~/Downloads/` unless you
say otherwise. On iOS they are in the
app's own folder, which you can see in the Files app under On My iPhone. Delete
the files, or the app, and they are gone. If your device is backed up — to
iCloud, or to a computer — that folder is backed up with the rest of it, by
Apple's software and under Apple's terms, not by this app.

## What the app fetches when you ask

Neither application reaches the network unless asked to. What asks is
`(download url)`, called by you or by a program you run. It fetches
that one `https://` address and saves what comes back; it sends nothing of
yours with the request. As with any web request, the server you name sees
your device's IP address and that the file was asked for.

On the Mac, the editor (heml) can also connect to another Lisp over a socket,
which happens only if you use its commands for that.

## What you run is up to you

Lisp Listener runs the code you give it. A program you type, load or open can
read and write the files the application itself can reach, and nothing more:
on iOS that is the app's own folder and any file you explicitly open; on the
Mac it is whatever your user account can reach. Open files from people you
trust, as you would with any program.

## What Apple may collect

If you install the iOS app through TestFlight or the App Store, Apple handles
the installation, and if you have agreed to share analytics with developers,
Apple may provide anonymous crash reports and usage statistics. TestFlight
feedback you choose to send — a screenshot, a comment — comes with your email
address. Those are Apple's services, covered by
[Apple's privacy policy](https://www.apple.com/legal/privacy/); the app itself
takes no part in them.

## Changes, and questions

If this ever changes it will change here first, in the repository's history.
Questions: open an issue at
<https://github.com/lispnik/lisp-listener-app/issues>, or write to
burnsidemk@gmail.com.

*5 October 2026*
