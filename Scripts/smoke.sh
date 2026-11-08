#!/bin/zsh
# Launch smoke test: app must open a window and raise no uncaught AppKit exception.
cd "$(dirname "$0")/.."
APP=DELIVERABLES/PrintProcessor.app
pkill -x PrintProcessor 2>/dev/null
"$APP/Contents/MacOS/PrintProcessor" >/dev/null 2>&1 &
sleep 5
W=$(osascript -e 'tell application "System Events" to count windows of process "PrintProcessor"' 2>/dev/null)
E=$(/usr/bin/log show --last 40s --process PrintProcessor --style compact --info --debug 2>&1 | grep -c "uncaught exception")
pkill -x PrintProcessor
echo "windows=$W exceptions=$E"
[ "$W" -ge 1 ] && [ "$E" -eq 0 ] && echo SMOKE_PASS || { echo SMOKE_FAIL; exit 1; }
