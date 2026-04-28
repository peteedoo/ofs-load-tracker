#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="OFS Load Tracker"
BUNDLE="$APP_NAME.app"
EXEC_NAME="OFSLoadTracker"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp Info.plist "$BUNDLE/Contents/Info.plist"

echo "Compiling..."
swiftc -O \
    -target arm64-apple-macos13 \
    -framework SwiftUI -framework AppKit -framework Vision \
    -parse-as-library \
    -o "$BUNDLE/Contents/MacOS/$EXEC_NAME" \
    OFSLoadTracker/*.swift

# Sign locally so Gatekeeper accepts it without quarantine drama
codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || true

echo ""
echo "Built: $(pwd)/$BUNDLE"
echo "Run:   open \"$BUNDLE\""
