#!/usr/bin/env bash
# Ensure the Android HCI snoop log is enabled and applied.
set -euo pipefail
ADB="tools/platform-tools/adb.exe"
"$ADB" shell "settings put global bluetooth_hci_snoop_log 1"
"$ADB" shell "cmd bluetooth_manager disable" >/dev/null
sleep 2
"$ADB" shell "cmd bluetooth_manager enable" >/dev/null
sleep 4
"$ADB" shell "dumpsys bluetooth_manager" | grep -i -m1 snoop
