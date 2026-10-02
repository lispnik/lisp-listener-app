#!/bin/sh
# tools/ios-demo.sh [DIR] -- a captioned video of the iOS app, from its self-test.
#
# The simulator records its own screen (`simctl io recordVideo', no permission
# needed), while the app's self-test drives a session: typing, paredit,
# completion, the history, an error and its sheet, a value, a form stopped.
# Each step the self-test logs becomes a caption, timed from the start of the
# recording.  Needs the app built (`make ios'), ffmpeg built with libass, and
# python3.
#
# DEVICE names the simulator, by the start of its name or by UDID (see
# tools/ios-device.sh): DEVICE=iPad is where the canvas docks beside the
# transcript.  Without it, whichever simulator is booted.  A simulator this
# boots, it shuts down again; the app is installed afresh either way.
#
# Writes DIR/lisp-listener-ios-demo.mp4 (default build/ios-demo).
set -eu
dir=${1:-build/ios-demo}
hold=${IOS_DEMO_HOLD:-3}
app=org.lispnik.lisp-listener
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)

booted_here=0
if [ -n "${DEVICE:-}" ]; then
  device=$("$(dirname "$0")/ios-device.sh" "$DEVICE") \
    || { echo "ios-demo: no simulator called $DEVICE" >&2; exit 1; }
  if ! xcrun simctl list devices booted | grep -q "$device"; then
    xcrun simctl boot "$device"
    booted_here=1
  fi
  xcrun simctl bootstatus "$device" -b > /dev/null
else
  device=$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -1)
  [ -n "$device" ] || { echo "ios-demo: no booted simulator, and no DEVICE" >&2; exit 1; }
fi
bundle="${APP:-build/iphonesimulator/Lisp Listener.app}"
[ -d "$bundle" ] || { echo "ios-demo: no $bundle -- run: make ios" >&2; exit 2; }
xcrun simctl terminate "$device" "$app" 2>/dev/null || true
xcrun simctl install "$device" "$bundle"
container=$(xcrun simctl get_app_container "$device" "$app" data)
mkdir -p "$container/Documents"
log="$container/Documents/console.log"

xcrun simctl terminate "$device" "$app" 2>/dev/null || true
: > "$log"
rm -f "$dir/raw.mp4" "$dir/steps.tsv"

xcrun simctl io "$device" recordVideo --codec h264 --force "$dir/raw.mp4" 2>/dev/null &
recorder=$!
sleep 1                                   # the recorder's first frame
start=$(python3 -c 'import time; print(time.time())')
SIMCTL_CHILD_LISP_LISTENER_SELF_TEST=$hold \
  xcrun simctl launch "$device" "$app" >/dev/null

# Each new `selftest: ok    <step>' line, with when it appeared.  Not under -e:
# a self-test that fails still has a video worth making, and says so at the end.
set +e
python3 - "$log" "$start" "$dir/steps.tsv" <<'EOF'
import sys, time, re
log, start, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
seen, deadline = 0, time.time() + 420
with open(out, 'w') as steps:
    while time.time() < deadline:
        try:
            lines = open(log).read().splitlines()
        except FileNotFoundError:
            lines = []
        for line in lines[seen:]:
            m = re.search(r'selftest: (ok|FAIL)\s+(.*)', line)
            if m:
                steps.write('%.2f\t%s%s\n' % (time.time() - start,
                                              '' if m.group(1) == 'ok' else 'FAILED: ',
                                              m.group(2)))
                steps.flush()
            if re.search(r'selftest: (PASS|FAIL \()', line):
                sys.exit(0 if 'PASS' in line else 1)
        seen = len(lines)
        time.sleep(0.2)
sys.exit(2)
EOF
verdict=$?
set -e
sleep 2
kill -INT "$recorder"; wait "$recorder" 2>/dev/null || true
[ "$booted_here" -eq 1 ] && xcrun simctl shutdown "$device"

# Captions: each step from when it was logged until the next one.
size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$dir/raw.mp4")
w=${size%x*} h=${size#*x}
band=260
python3 - "$dir" "$w" "$((h + band))" <<'EOF'
import sys
d, w, h = sys.argv[1], sys.argv[2], sys.argv[3]
steps = [l.rstrip('\n').split('\t', 1) for l in open(d + '/steps.tsv') if '\t' in l]
def ts(t):
    t = max(0.0, t)
    return "%d:%02d:%05.2f" % (int(t // 3600), int(t % 3600 // 60), t % 60)
ass = ["[Script Info]", "ScriptType: v4.00+", "PlayResX: " + w, "PlayResY: " + h, "",
       "[V4+ Styles]",
       "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
       "Style: Cap,Helvetica Neue,64,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,60,60,70,1",
       "", "[Events]", "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"]
for i, (t, text) in enumerate(steps):
    end = float(steps[i + 1][0]) if i + 1 < len(steps) else float(t) + 4
    ass.append("Dialogue: 0,%s,%s,Cap,,0,0,0,,%s" % (ts(float(t)), ts(end), text))
open(d + '/captions.ass', 'w').write('\n'.join(ass) + '\n')
EOF

ffmpeg -hide_banner -loglevel error -y -i "$dir/raw.mp4" \
  -vf "pad=${w}:$((h + band)):0:0:color=0x141414,subtitles=$dir/captions.ass,scale=-2:1600,format=yuv420p" \
  -r 30 -c:v libx264 -crf 22 -preset slow -movflags +faststart \
  "$dir/lisp-listener-ios-demo.mp4"
echo "$dir/lisp-listener-ios-demo.mp4"
[ "$verdict" -eq 0 ] || { echo "ios-demo: the self-test did not pass" >&2; exit 1; }
