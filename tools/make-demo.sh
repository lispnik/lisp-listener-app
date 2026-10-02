#!/bin/sh
# tools/make-demo.sh DIR -- turn what LISP_LISTENER_DEMO=DIR wrote into a video.
#
# DIR holds frames/, frames.txt and captions.tsv (see src/macos/demo.lisp).
# Writes DIR/lisp-listener-demo.mp4: a title card, the session with its
# captions in a band under the window, and a closing card.  Needs ffmpeg built
# with libass -- Homebrew's ffmpeg-full, not its ffmpeg -- and ImageMagick.
# `make demo' runs the whole thing.
set -eu
dir=$(cd "$1" && pwd)
cd "$dir"

# The frame size, from the first frame; the cards and the caption band follow it.
size=$(magick identify -format '%wx%h' frames/00001.png)
w=${size%x*} h=${size#*x}
band=140
# H.264 in yuv420p wants even sides, and a 1x display -- a CI runner's -- gives
# a window an odd height.  The band takes the extra row.
w_even=$(( (w + 1) / 2 * 2 ))
h_even=$(( (h + band + 1) / 2 * 2 ))
# The cards' type is set for a 1720-pixel frame (a 2x display) and scaled to
# this one: at 1x the longest line ran off both sides.
pt() { echo $(( $1 * w / 1720 )); }
bold="/System/Library/Fonts/Supplemental/Arial Bold.ttf"
regular=/System/Library/Fonts/SFNS.ttf

magick -size "${w}x${h}" xc:'#1e1e1e' -gravity center \
  -font "$bold" -pointsize $(pt 96) -fill white -annotate +0-$(pt 90) 'Lisp Listener' \
  -font "$regular" -pointsize $(pt 44) -fill '#9a9a9a' -annotate +0+$(pt 30) 'A Lisp REPL in a native Mac window' \
  -pointsize $(pt 34) -fill '#6f6f6f' -annotate +0+$(pt 110) 'SBCL on macOS  ·  ECL on iOS' title.png
magick -size "${w}x${h}" xc:'#1e1e1e' -gravity center \
  -font "$bold" -pointsize $(pt 64) -fill white -annotate +0-$(pt 120) 'Lisp Listener' \
  -font "$regular" -pointsize $(pt 36) -fill '#9a9a9a' -annotate +0-$(pt 20) 'Option-Return · paredit · ⌘R history · ⌘. interrupt' \
  -annotate +0+$(pt 40) 'a debugger docked under the transcript: frames, locals, ⌘-number restarts' \
  -pointsize $(pt 30) -fill '#6f6f6f' -annotate +0+$(pt 130) 'github.com/lispnik/lisp-listener-app' end.png

python3 - "$dir" "$w_even" "$h_even" <<'EOF'
import sys
d, w, h = sys.argv[1], sys.argv[2], sys.argv[3]
TITLE, FPS = 3.0, 30
# Each frame's duration rounded to whole 1/30ths.  Left as recorded, a 0.055s
# keystroke frame is stretched to 0.067s by the constant frame rate, and over a
# few hundred of them the picture fell seconds behind the captions.  The
# captions are then timed from these same rounded durations.
lines = open('frames.txt').read().split('\n')
pairs = [(lines[i], float(lines[i + 1].split()[1])) for i in range(0, len(lines) - 2, 2)
         if lines[i].startswith('file')]
body, starts, t, q = [], [], 0.0, 0.0
for f, dur in pairs:
    n = max(1, round(dur * FPS))
    starts.append((t, q))
    body += [f, "duration %.6f" % (n / FPS)]
    t += dur; q += n / FPS
starts.append((t, q))
def video_time(t0):
    """The rounded time of the frame showing at recorded time T0."""
    for (a, qa), (b, qb) in zip(starts, starts[1:]):
        if a <= t0 < b:
            return qa
    return starts[-1][1]
out = ["file '%s/title.png'" % d, "duration %.3f" % TITLE] + body + \
      ["file '%s/end.png'" % d, "duration 4.0", "file '%s/end.png'" % d]
open('all.txt', 'w').write('\n'.join(out) + '\n')
def ts(t):
    return "%d:%02d:%05.2f" % (int(t // 3600), int(t % 3600 // 60), t % 60)
ass = ["[Script Info]", "ScriptType: v4.00+", "PlayResX: " + w, "PlayResY: " + h, "",
       "[V4+ Styles]",
       "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
       "Style: Cap,Helvetica Neue,46,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,60,60,42,1",
       "", "[Events]", "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"]
for l in open('captions.tsv'):
    a, b, t = l.rstrip('\n').split('\t')
    ass.append("Dialogue: 0,%s,%s,Cap,,0,0,0,,%s" % (ts(video_time(float(a)) + TITLE),
                                                     ts(video_time(float(b)) + TITLE),
                                                     t.replace('--', '—')))
open('captions.ass', 'w').write('\n'.join(ass) + '\n')
EOF

ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i all.txt \
  -vf "pad=${w_even}:${h_even}:0:0:color=0x141414,subtitles=captions.ass,format=yuv420p" \
  -fps_mode cfr -r 30 -c:v libx264 -crf 20 -preset slow -movflags +faststart \
  lisp-listener-demo.mp4
echo "$dir/lisp-listener-demo.mp4"
