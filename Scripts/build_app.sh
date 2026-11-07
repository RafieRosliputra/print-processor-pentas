#!/bin/bash
# Builds PrintProcessor into a self-contained .app bundle.
#
# There is no Xcode on this machine, so the bundle is assembled by hand around a
# SwiftPM release binary: Contents/MacOS + Info.plist + ad-hoc signature. That is
# enough for a locally distributed app and avoids the Xcode project entirely.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="$ROOT/DELIVERABLES/PrintProcessor.app"
CONFIG="${CONFIG:-release}"

UNIVERSAL="${UNIVERSAL:-0}"
ARCH_FLAGS=""
[ "$UNIVERSAL" = "1" ] && ARCH_FLAGS="--arch arm64 --arch x86_64"

echo "== swift build -c $CONFIG ${ARCH_FLAGS} =="
# shellcheck disable=SC2086
swift build -c "$CONFIG" $ARCH_FLAGS 2>&1 | grep -vE "search path .* not found" || true

BINARY="$ROOT/.build/$CONFIG/PrintProcessor"
if [ ! -x "$BINARY" ]; then
    echo "build produced no binary at $BINARY" >&2
    exit 1
fi

echo "== assemble bundle =="
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BINARY" "$OUT/Contents/MacOS/PrintProcessor"
cp "$ROOT/Resources/Info.plist" "$OUT/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$OUT/Contents/PkgInfo"

echo "== codesign (ad-hoc) =="
codesign --force --sign - --timestamp=none "$OUT" 2>&1 | sed 's/^/  /'

echo "== verify =="
codesign --verify --deep --strict "$OUT" && echo "  signature ok"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$OUT/Contents/Info.plist"
ls -la "$OUT/Contents/MacOS"
echo "built: $OUT"
