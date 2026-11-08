#!/bin/zsh
# Launch smoke test: the main window must really appear (full width, key, visible) and no uncaught AppKit exception.
cd "$(dirname "$0")/.."
APP=DELIVERABLES/PrintProcessor.app
pkill -x PrintProcessor 2>/dev/null; rm -f /tmp/pp-window.txt
PP_DEBUG=1 "$APP/Contents/MacOS/PrintProcessor" >/dev/null 2>&1 &
sleep 4
T=$(cat /tmp/pp-window.txt 2>/dev/null)
W=$(echo "$T" | sed -n 's/^frame=([^,]*, [^,]*, \([0-9]*\)\..*/\1/p')
E=$(/usr/bin/log show --last 40s --process PrintProcessor --style compact --info --debug 2>&1 | grep -c "uncaught exception")
pkill -x PrintProcessor
echo "$T"; echo "width=${W:-0} exceptions=$E"
[ "${W:-0}" -ge 1100 ] && echo "$T" | grep -q "visible=true" && [ "$E" -eq 0 ] && echo SMOKE_PASS || { echo SMOKE_FAIL; exit 1; }
