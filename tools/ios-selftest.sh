#!/bin/bash
# tools/ios-selftest.sh [DEVICE...] -- the iOS app's self-test, in simulators.
#
#     make test-ios                     # an iPhone and an iPad
#     tools/ios-selftest.sh "iPad mini (A17 Pro)"
#     SHOTS=build/ios-shots HOLD=2 tools/ios-selftest.sh
#
# Installs build/iphonesimulator/Lisp Listener.app in each simulator, launches
# it with LISP_LISTENER_SELF_TEST set, and waits for the verdict the app writes
# to Documents/console.log.  Exits 0 only if every device said PASS.
#
# An iPhone AND an iPad by default, and that is the point of it: the iPad is
# not a big phone.  Its focus engine walks a table a phone leaves alone, which
# was a crash on every Cancel that only the iPad showed; and it is where the
# canvas docks instead of coming up as a sheet.
#
# A device is a name or a UDID.  A simulator this boots, it shuts down again.
# SHOTS=dir keeps a screenshot every second and a half, for looking at; HOLD=n
# holds n seconds on each screen the self-test thinks worth a look.
set -u

app="${APP:-build/iphonesimulator/Lisp Listener.app}"
bundle=org.lispnik.lisp-listener
hold="${HOLD:-0}"
limit="${LIMIT:-240}"

[ -d "$app" ] || { echo "ios-selftest: no $app -- run: make ios" >&2; exit 2; }

newest() { "$(dirname "$0")/ios-device.sh" "$1"; }

if [ $# -eq 0 ]; then set -- "iPhone" "iPad"; fi

failed=0
for want in "$@"; do
  udid=$(newest "$want") || { echo "ios-selftest: no simulator called $want" >&2; failed=1; continue; }
  name=$(xcrun simctl list devices | sed -n "s/^ *\(.*\) ($udid).*/\1/p" | head -1)
  booted_here=0
  if ! xcrun simctl list devices booted | grep -q "$udid"; then
    xcrun simctl boot "$udid" || { failed=1; continue; }
    booted_here=1
  fi
  xcrun simctl bootstatus "$udid" -b > /dev/null

  xcrun simctl terminate "$udid" "$bundle" > /dev/null 2>&1
  xcrun simctl install "$udid" "$app" || { failed=1; continue; }
  container=$(xcrun simctl get_app_container "$udid" "$bundle" data)
  log="$container/Documents/console.log"
  rm -f "$log"
  SIMCTL_CHILD_LISP_LISTENER_SELF_TEST="$hold" xcrun simctl launch "$udid" "$bundle" > /dev/null

  verdict=""
  shot=0
  start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt "$limit" ]; do
    sleep 1.5
    if [ -n "${SHOTS:-}" ]; then
      mkdir -p "$SHOTS"
      shot=$((shot + 1))
      xcrun simctl io "$udid" screenshot \
        "$SHOTS/$(echo "$name" | tr ' ()' '---')-$(printf %03d $shot).png" > /dev/null 2>&1
    fi
    verdict=$(grep -o "selftest: \(PASS\|FAIL ([0-9]*)\)" "$log" 2>/dev/null | tail -1)
    [ -n "$verdict" ] && break
    # Gone without a verdict is a crash, and waiting out the limit says less.
    if ! xcrun simctl spawn "$udid" launchctl list 2>/dev/null | grep -q "$bundle"; then
      verdict="selftest: the app is no longer running"
      break
    fi
  done

  steps=$(grep -c "selftest: ok" "$log" 2>/dev/null || true)
  case "$verdict" in
    "selftest: PASS") echo "ios-selftest: $name: PASS, $steps steps" ;;
    *) echo "ios-selftest: $name: ${verdict:-no verdict after ${limit}s}, after $steps steps" >&2
       grep "selftest: FAIL" "$log" >&2 2>/dev/null
       tail -3 "$log" >&2 2>/dev/null
       failed=1 ;;
  esac
  [ "$booted_here" -eq 1 ] && xcrun simctl shutdown "$udid"
done
exit $failed
