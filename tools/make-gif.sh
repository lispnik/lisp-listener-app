#!/bin/sh
# tools/make-gif.sh DIR OUT FIRST [LAST] -- a GIF of part of the demo, for the README.
#
#     tools/make-gif.sh build/demo doc/canvas.gif 'canvas to draw' 'Snake'
#
# DIR is what `make demo' left: the video and captions.tsv.  The GIF runs from
# the start of the first caption containing FIRST to the end of the first one
# containing LAST (FIRST's own end, without LAST), so a scene is named by what
# it says and not by a time that moves whenever the script before it changes.
# Half size, ten frames a second, a palette of its own and no dithering -- flat
# colour is what a GIF compresses, and a window is mostly that: a GitHub page
# shows a GIF where it will only link to a video.
set -eu
dir=$1 out=$2 first=$3 last=${4:-$3}
range=$(python3 - "$dir/captions.tsv" "$first" "$last" <<'PY'
import sys
rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1])]
start = next(float(a) for a, b, t in rows if sys.argv[2] in t)
end = next(float(b) for a, b, t in rows if sys.argv[3] in t)
# The video opens on a three-second title card the captions do not count.
print("%.3f %.3f" % (start + 3.0, end - start))
PY
)
set -- $range
ffmpeg -hide_banner -loglevel error -y -ss "$1" -t "$2" -i "$dir/lisp-listener-demo.mp4" \
  -vf "fps=10,scale=860:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=none" \
  "$out"
ls -l "$out"
