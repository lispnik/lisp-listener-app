#!/bin/sh
# tools/store-shots.sh DEVICE DIR -- the App Store's screenshots, from the app.
#
# Launches the app with LISP_LISTENER_STORE_SHOTS set, which plays a short,
# clean session (build-store-steps, src/ios/app.lisp) and logs `storeshot:
# NAME' as each screen is ready; each is photographed as DIR/NAME.png.  The
# status bar is Apple's: 9:41, full signal, full battery.  Needs `make ios'.
#
#     tools/store-shots.sh "iPhone 18 Pro Max" build/store/iphone   # 1320 x 2868
#     tools/store-shots.sh "iPad Pro 13-inch (M5)" build/store/ipad # 2064 x 2752
set -eu
want=$1; dir=$2
app=org.lispnik.lisp-listener
bundle="${APP:-build/iphonesimulator/Lisp Listener.app}"
device=$("$(dirname "$0")/ios-device.sh" "$want")
mkdir -p "$dir"
booted_here=0
if ! xcrun simctl list devices booted | grep -q "$device"; then
  xcrun simctl boot "$device"; booted_here=1
fi
xcrun simctl bootstatus "$device" -b > /dev/null
xcrun simctl status_bar "$device" override --time 9:41 --dataNetwork wifi \
  --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100
xcrun simctl terminate "$device" "$app" 2>/dev/null || true
xcrun simctl install "$device" "$bundle"
log="$(xcrun simctl get_app_container "$device" "$app" data)/Documents/console.log"
rm -f "$log"
SIMCTL_CHILD_LISP_LISTENER_STORE_SHOTS=${HOLD:-6} xcrun simctl launch "$device" "$app" > /dev/null
taken=""
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt 300 ]; do
  for name in $(sed -n 's/.*storeshot: //p' "$log" 2>/dev/null); do
    case " $taken " in *" $name "*) ;; *)
      sleep 1.5                     # let an animation finish
      xcrun simctl io "$device" screenshot "$dir/$name.png" > /dev/null
      echo "store-shots: $dir/$name.png"
      taken="$taken $name" ;;
    esac
  done
  grep -q "selftest: \(PASS\|FAIL\)" "$log" 2>/dev/null && break
  sleep 0.3
done
grep "selftest: FAIL" "$log" || true
xcrun simctl status_bar "$device" clear
[ "$booted_here" = 1 ] && xcrun simctl shutdown "$device"
true
