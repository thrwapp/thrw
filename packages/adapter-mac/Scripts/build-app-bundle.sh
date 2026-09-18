#!/bin/bash
# Assembles AdapterMac.app from the AdapterMacApp executable target
# (#128). Plain SwiftPM has no built-in notion of a macOS .app bundle -
# `swift build` alone only produces a bare Unix executable, which is not
# enough for anything IOBluetoothPeripheralGateway does:
# NSBluetoothAlwaysUsageDescription (Info.plist) is read from
# Bundle.main, which a bare executable run outside a real .app bundle
# does not have populated - see Info.plist's own comment.
#
# Not run by `swift build`/`swift test` (CI's mac-ipad job, and this
# repo's own agent-code/agent-eval automation, only need those two) -
# this is for a human building a real, runnable app locally.
#
# Deliberately does NOT codesign or notarize: that needs a real Apple
# Developer Program team identity, which does not exist yet (#132) -
# see docs/handoffs/128.md's "Known gaps". The unsigned bundle below
# still runs locally (System Settings > Privacy & Security > "Open
# Anyway" for an unsigned app on first launch), which is enough to
# develop and test against.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONFIGURATION="${1:-debug}"
BUILD_FLAG=""
if [ "$CONFIGURATION" = "release" ]; then
  BUILD_FLAG="-c release"
fi

swift build $BUILD_FLAG --product AdapterMacApp

BIN_PATH=$(swift build $BUILD_FLAG --show-bin-path)
APP_BUNDLE="$BIN_PATH/AdapterMac.app"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BIN_PATH/AdapterMacApp" "$APP_BUNDLE/Contents/MacOS/AdapterMacApp"
cp "Sources/AdapterMacApp/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "Built $APP_BUNDLE (unsigned - see this script's own comment)"
