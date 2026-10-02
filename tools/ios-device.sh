#!/bin/bash
# tools/ios-device.sh NAME -- the UDID of a simulator, by the start of its name.
#
#     tools/ios-device.sh iPad          # the first iPad of the newest iOS
#     tools/ios-device.sh "iPhone 18"
#
# The newest runtime's first device whose name starts with NAME, or the device
# whose UDID is NAME.  So "an iPhone" and "an iPad" go on meaning something as
# Xcode's list of simulators changes under them.  Exits 1 when there is none.
xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
want = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
def version(key):
    return [int(n) for n in key.rsplit("iOS-", 1)[-1].split("-") if n.isdigit()]
for runtime in sorted((k for k in devices if "iOS" in k), key=version, reverse=True):
    for device in devices[runtime]:
        if device["name"].startswith(want) or device["udid"] == want:
            print(device["udid"]); sys.exit(0)
sys.exit(1)' "$1"
