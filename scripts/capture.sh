#!/usr/bin/env bash
# Pull the Android HCI snoop log off the tablet and decode it into Boya frames.
#   ./scripts/capture.sh [name]        -> research/capture/<name>.zip + .log + .frames.txt
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="${1:-capture-$(date +%H%M%S)}"
ADB="tools/platform-tools/adb.exe"
OUT="research/capture"
mkdir -p "$OUT"

"$ADB" devices | grep -q "device$" || { echo "no authorized device — run: $ADB devices"; exit 1; }
echo "taking bugreport (takes ~30 s)…"
"$ADB" bugreport "$OUT/$NAME.zip" >/dev/null 2>&1
unzip -o -q "$OUT/$NAME.zip" "FS/data/misc/bluetooth/logs/btsnoop_hci.log" -d "$OUT/$NAME.d"
LOG="$OUT/$NAME.d/FS/data/misc/bluetooth/logs/btsnoop_hci.log"
cp "$LOG" "$OUT/$NAME.log"
echo "log: $(wc -c < "$LOG") bytes"
uv run --quiet python -m notra selftest "$LOG" | tee "$OUT/$NAME.frames.txt"
echo
echo "next:  uv run python research/decode_btsnoop.py $OUT/$NAME.log"
