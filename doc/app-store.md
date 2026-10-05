# App Store Connect copy

What to paste into the fields App Store Connect asks for, each within its
limit, describing the app as it is now: the canvas, the examples, files from
the Files app, and the iPad's docked canvas are all in the build. The
TestFlight fields come first, because internal testing needs only those; the
App Store fields are for when the app is submitted.

Every field here was counted against its limit. Count again after an edit:
App Store Connect refuses a field one character over.

## TestFlight › Test Information

**Beta App Description** (4000)

```
Lisp Listener is a Common Lisp REPL for iPhone and iPad. Type a form, press
Return, and its value, its output and the debugger all come back in the same
transcript -- what LispWorks calls a Listener.

It runs ECL, a complete Common Lisp, entirely on the device. Nothing is sent
anywhere and no account is needed.

- Parens and quotes close themselves, and the matching paren is tinted.
- Tab completes symbols. The arrows walk your history, and Hist searches it.
- An error opens a sheet of restarts, with the backtrace below. Tap one, and
  if it needs a value, type it there.
- Stop interrupts a form that is still running.
- There is a canvas to draw on: (circle 0 0 50). On an iPad it sits beside
  the transcript; on a phone it is a sheet. It takes a finger, too.
- Try lists thirteen short examples -- a spiral, a fractal tree, the Mandelbrot
  set, Conway's Life, Snake, Pong -- each a screen of Lisp to read and change.
- (inspect x) opens an inspector: a byte vector as a histogram or as hex, a
  table's entries, an object's slots. Tap a row to change it or walk into it.
- Open loads a .lisp file from the Files app, and Files can open one in Lisp
  Listener.
- Edit opens an editor with the same paredit, completion and indenting, and
  Eval sends the form at the cursor to the listener.
- (asdf:load-system "name") loads a library put under common-lisp/ in the
  app's folder, and (download url) fetches a file into that folder.
- A bar above the keyboard has the keys a phone lacks: Tab, Esc, the arrows,
  Hist, Try, Open, Clear, Stop and a gear for Settings. A hardware keyboard
  gets the same keys as on a Mac.
```

**What to Test** (4000)

```
The things most worth trying:

1. Type (+ 1 2) and press Return. Then something with output:
   (dotimes (i 3) (print i))
2. Type ( and watch it close itself. Type (mapc and press Tab.
3. Make an error on purpose: (car 7). A sheet of restarts comes up. Tap
   "Return to the listener's top level", or press Backtrace to see the frames.
4. Type (loop) and press Return, then Stop on the key bar. The prompt should
   come back.
5. Tap Hist to search what you have typed, and tap a row to bring it back.
6. Tap Try, choose (example "spiral") and press Return: a canvas comes up with
   the drawing. Then (example "snake"), steered with the arrows under the
   canvas, and (example "doodle"), which draws where your finger goes.
7. Draw something yourself: (circle 0 0 50), then (forward 40) (right 90) a
   few times. (save "mine.png") puts the picture in the app's folder in Files.
8. In the Files app, long-press a .lisp file, choose Share or Open With, and
   pick Lisp Listener: it should load, with the (load ...) shown at the prompt.
   Open on the key bar does the same from inside the app.
9. On an iPad, the canvas should sit beside the transcript and leave you the
   keyboard. With a hardware keyboard: Option-Return starts a new indented
   line, Cmd-. stops, Cmd-K clears, Cmd-+ and Cmd-- change the size of the type.
10. Type (inspect (list 1 2 3)): a sheet comes up. Tap a row, type a form in
    the field and tap Set; try Insert, Remove and Add, and the other views
    along the top. Then (example "thermal"): move a slider, touch the picture.
    With the keyboard up, tap a value printed in the transcript: it opens too.
11. Tap the gear at the end of the key bar: the switches should take effect at
    once, and the stepper should resize everything in the transcript.
12. Tap Edit on the key bar: type a defun, tap Eval, then Close and call it at
    the prompt. Tap Edit again and the file is as you left it.
13. Rotate the device. On an iPad with the canvas up, narrow the window: the
    canvas should become a sheet, and dock again when there is room.

Please report anything that hangs, any key that does nothing, and any place
the keyboard covers what you are typing.
```

**Feedback Email:** burnsidemk@gmail.com

**Beta App Review › Sign-in required:** No.

**Beta App Review › Notes** (for external testers; internal testing needs no review)

```
Lisp Listener is a programming environment: a Common Lisp REPL (ECL) that
evaluates code the user types on the device, with a canvas the code can draw
on. It is an educational and developer tool, and like any programming
environment it runs only the code its user writes, opens or fetches. The one
network feature is (download url), which saves a file from an https address
the user types into the app's own folder, to be read or loaded by the user;
nothing is fetched otherwise. No accounts, no in-app purchases, and no data
collected. The examples it lists are part of the app. To try it, type (+ 1 2) and press
Return, or tap Try and choose an example.
```

## App Store › App Information

| Field | Limit | Value |
|---|---|---|
| Name | 30 | `Lisp Listener` |
| Subtitle | 30 | `Common Lisp REPL and a canvas` |
| Primary category | | Developer Tools |
| Secondary category | | Education |
| Content rights | | Does not contain third-party content |
| Age rating | | 4+ (answer None to every question) |

## App Store › Version Information

**Promotional Text** (170; can be changed without a new build)

```
A real Common Lisp in your pocket: a REPL with paredit, completion and a debugger, and a canvas to draw on. Type (example "snake") and play what a page of Lisp can do.
```

**Description** (4000)

```
Lisp Listener is a Common Lisp REPL for iPhone and iPad. Type a form and press Return: its value, its output and the debugger come back in the same transcript.

It runs ECL, a complete ANSI Common Lisp, entirely on your device. There is no server and no account: what you type stays on your phone.

WRITING LISP ON GLASS
• Parens and quotes close themselves, and typing the closer steps over the one already there.
• The paren at the cursor and its partner are tinted, red when it has none.
• Tab completes the symbol you are typing, from the current package.
• Option-Return starts a new line indented the way Lisp is indented.
• A bar above the keyboard has the keys a phone keyboard lacks: Tab, Esc, the arrows, history, examples, Open, Clear, Stop and Settings.

A DEBUGGER, NOT A CRASH
• An error opens a sheet listing the restarts, each with its report, exactly as Common Lisp's condition system offers them.
• A restart that needs a value asks for it right there.
• The backtrace is one tap away.
• An error at a debugger prompt opens the next level down, as it should.
• Stop interrupts a form that is still running.

A CANVAS TO DRAW ON
• (circle 0 0 50) draws a circle. So do lines, dots, boxes, text, the graph of a function, and a turtle that walks forward and turns.
• On an iPad the canvas sits beside the transcript, so you type a form and watch what it draws. On an iPhone it is a sheet.
• (frame ...) and (wait ...) animate. (key) reads the arrows under the canvas and (pointer) reads your finger, so a game is a page of code.
• (save "mine.png") keeps the picture, in the app's folder in Files.

THIRTEEN EXAMPLES TO TAKE APART
• A rainbow spiral, a rose curve, a fractal tree, Sierpinski's triangle, the Mandelbrot set, a clock, bouncing balls, Conway's Life, a doodle, Snake, Pong and a simulated hot plate.
• Each is a screen of Lisp. Run one, read it, or put it at the prompt and change it.

AN INSPECTOR
• (inspect x) opens an inspector, in the view that suits the value: an object's slots, a table's entries, a byte vector as a histogram or hex. Tap a row to change it.
• Several views apply to most things, and you can add your own for your own data.

YOUR FILES AND YOUR HISTORY
• Open a .lisp file from the Files app or a share sheet and it is loaded. The app's folder is in Files, so your own code is a tap away.
• An editor with the same paredit, completion and indenting: Eval sends the form at the cursor to the listener, and Load loads the file.
• ASDF is built in: put a library under common-lisp/ in the app's folder and (asdf:load-system "name") loads it. (download url) fetches a file there.
• The arrows walk back through what you have typed, and history search narrows as you type.
• Settings has the switches and the size of the type; they and your history are kept between launches.

WITH A KEYBOARD
On an iPad with a keyboard it works like a desktop Lisp: Tab, the arrows, Escape, Cmd-. to stop, Cmd-K to clear, Cmd-R to search, Cmd-O to open, Cmd-+ and Cmd-- for the size of the type, and Cmd-0 to Cmd-9 to choose a restart.

OPEN SOURCE
Lisp Listener is free and open source. The same listener runs on the Mac, with SBCL.
```

**Keywords** (100, comma-separated, no spaces after commas)

```
lisp,common lisp,repl,ecl,programming,code,interpreter,debugger,turtle,graphics,learn,coding,sbcl
```

**Support URL:** https://github.com/lispnik/lisp-listener-app/issues

**Marketing URL:** https://github.com/lispnik/lisp-listener-app

**Copyright:** 2026 Matthew Kennedy

## App Privacy

**Data Not Collected.** Nothing typed into the app leaves the device. Its only
network request is `(download url)`, a fetch of an address the user types,
which sends nothing of theirs.

**Privacy Policy URL:** https://github.com/lispnik/lisp-listener-app/blob/main/PRIVACY.md

Required for the App Store and for external TestFlight testers, not for
internal ones. The page is `PRIVACY.md` at the top of the repository.

## Export compliance

Already answered in the bundle: `ITSAppUsesNonExemptEncryption` is false.

## Which build has what

| Build | Adds |
|---|---|
| 0.1.51 | the listener: REPL, paredit, completion, history, the debugger sheet |
| 0.1.52 | the canvas and six examples |
| 0.1.53 | files from the Files app; the iPad crash on Cancel fixed |
| 0.1.54 | a closed canvas stays closed |
| 0.1.56 | touch on the canvas, the docked canvas on iPad, Open, saving a picture, twelve examples, Settings and the size of the type |
| 0.1.58 | C-a goes to the start of the line, after the prompt |
| 0.1.61 | (inspect x), printed as text; a thirteenth example |
| 0.1.62 | the inspector as a sheet: views, options and controls, Set, Insert, Remove and Add, a readout under a finger |
| 0.1.70 | a tap on a printed value inspects it; Views lists every view; values are no longer blue or printed twice; a sheet can no longer be left up; argument hints; (download url); init.lisp from Settings; ASDF; the editor |

Everything above describes 0.1.70. Do not paste it over an older one.
