# App Store Connect copy

What to paste into the fields App Store Connect asks for, each within its
limit. The TestFlight fields come first, because internal testing needs only
those; the App Store fields are for when the app is submitted.

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
- A bar above the keyboard has the keys a phone lacks: Tab, Esc, the arrows,
  Hist, Clear and Stop. A hardware keyboard gets the same keys as on a Mac.
```

**What to Test** (4000)

```
This is the first build. The things most worth trying:

1. Type (+ 1 2) and press Return. Then something with output:
   (dotimes (i 3) (print i))
2. Type ( and watch it close itself. Type (mapc and press Tab.
3. Make an error on purpose: (car 7). A sheet of restarts comes up. Tap
   "Return to the listener's top level", or press Backtrace to see the frames.
4. Type (loop) and press Return, then Stop on the key bar. The prompt should
   come back.
5. Tap Hist to search what you have typed, and tap a row to bring it back.
6. Rotate the device, and try it on an iPad with a keyboard if you have one:
   Option-Return starts a new indented line, Cmd-. stops, Cmd-K clears.

Please report anything that hangs, any key that does nothing, and any place
the keyboard covers what you are typing.
```

**Feedback Email:** burnsidemk@gmail.com

**Beta App Review › Sign-in required:** No.

**Beta App Review › Notes** (for external testers; internal testing needs no review)

```
Lisp Listener is a programming environment: a Common Lisp REPL (ECL) that
evaluates code the user types on the device. It is an educational and
developer tool. It downloads no code, has no network features, no accounts
and no in-app purchases, and collects no data. To try it, type (+ 1 2) and
press Return.
```

## App Store › App Information

| Field | Limit | Value |
|---|---|---|
| Name | 30 | `Lisp Listener` |
| Subtitle | 30 | `Common Lisp REPL and debugger` |
| Primary category | | Developer Tools |
| Secondary category | | Education |
| Content rights | | Does not contain third-party content |
| Age rating | | 4+ (answer None to every question) |

## App Store › Version Information

**Promotional Text** (170; can be changed without a new build)

```
A real Common Lisp in your pocket: type a form, get its value, and when it goes wrong, pick a restart. Paredit, completion, history and a debugger, all on the device.
```

**Description** (4000)

```
Lisp Listener is a Common Lisp REPL for iPhone and iPad. Type a form and press Return: its value, its output and the debugger come back in the same transcript.

It runs ECL, a complete ANSI Common Lisp, entirely on your device. There is no server, no account and no network: what you type stays on your phone.

WRITING LISP ON GLASS
• Parens and quotes close themselves, and typing the closer steps over the one already there.
• The paren at the cursor and its partner are tinted, red when it has none.
• Tab completes the symbol you are typing, from the current package.
• Option-Return starts a new line indented the way Lisp is indented.
• A bar above the keyboard has the keys a phone keyboard lacks: Tab, Esc, the arrows, history, Clear and Stop.

A DEBUGGER, NOT A CRASH
• An error opens a sheet listing the restarts, each with its report, exactly as Common Lisp's condition system offers them.
• A restart that needs a value asks for it right there.
• The backtrace is one tap away.
• An error at a debugger prompt opens the next level down, as it should.
• Stop interrupts a form that is still running.

YOUR HISTORY
• The arrows walk back through what you have typed.
• History search narrows as you type and puts your choice back at the prompt to edit.
• History is kept between launches.

WITH A KEYBOARD
On an iPad with a keyboard it works like a desktop Lisp: Tab, the arrows, Escape, Cmd-. to stop, Cmd-K to clear, Cmd-R to search, and Cmd-0 to Cmd-9 to choose a restart.

OPEN SOURCE
Lisp Listener is free and open source. The same listener runs on the Mac, with SBCL.
```

**Keywords** (100, comma-separated, no spaces after commas)

```
lisp,common lisp,repl,ecl,programming,code,interpreter,debugger,paredit,functional,sbcl,learn,coding
```

**Support URL:** https://github.com/lispnik/sbcl-macos/issues

**Marketing URL:** https://github.com/lispnik/sbcl-macos

**Copyright:** 2026 Matthew Kennedy

## For a build with the canvas (0.1.52 on)

Build 0.1.51, the first, has neither the canvas nor the examples, so nothing
above mentions them. For a build that has them:

**Beta App Description**, one more line:

```
- Try, on the bar above the keyboard, lists six short examples -- a spiral, a
  fractal tree, Conway's Life, Snake -- that draw on a canvas you can draw on
  too: (circle 0 0 50).
```

**What to Test**, one more step:

```
7. Tap Try, choose (example "spiral") and press Return. A canvas comes up with
   the drawing. Then try (example "snake"), and steer with the arrows under it.
```

and, from 0.1.53, which opens files:

```
8. In the Files app, long-press a .lisp file, choose Share or Open With, and
   pick Lisp Listener: it should load, with the (load ...) shown at the prompt.
   The app's own folder is under On My iPhone > Lisp Listener.
```

**Description**, a section before WITH A KEYBOARD:

```
A CANVAS TO DRAW ON
• (circle 0 0 50) draws a circle. So do lines, dots, boxes, text, the graph of a function, and a turtle that walks forward and turns.
• Six short examples come with it: a rainbow spiral, a rose curve, a fractal tree, Conway's Life and a game of Snake. Each is a screen of Lisp you can read and change.
• (frame ...) and (wait ...) animate, and (key) reads the arrows under the canvas, so a game is a dozen lines.
```

and one more line under YOUR HISTORY's section, or after it:

```
FILES
• Open a .lisp file from the Files app or a share sheet and it is loaded. The app's folder is in Files, so your own code and init.lisp are a tap away.
```

**Promotional Text**, in place of the one above:

```
A real Common Lisp in your pocket: a REPL with paredit, completion and a debugger, and a canvas to draw on. Type (example "snake") and play what a page of Lisp can do.
```

## App Privacy

**Data Not Collected.** The app has no network code; nothing typed into it
leaves the device. A privacy policy URL is still required for the App Store
(not for internal TestFlight): a page saying exactly that is enough.

## Export compliance

Already answered in the bundle: `ITSAppUsesNonExemptEncryption` is false.
