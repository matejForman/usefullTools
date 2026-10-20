#!/bin/bash
# Builds TrainingHelper.app (needs Xcode Command Line Tools: xcode-select --install; macOS 14+)
#
# Signing: macOS ties the Screen Recording / Accessibility permissions to the app's code signature.
# An ad-hoc signature changes with every build, so macOS forgets the permissions each time.
# Create a certificate once (see SETUP.txt) and this script signs every build with it, so the
# permissions stay. Use another identity with:  SIGN_ID="Apple Development: ..." bash build.sh
set -e
cd "$(dirname "$0")"

APP="TrainingHelper.app"
IDENTITY="${SIGN_ID:-TrainingHelper Dev}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -Ounchecked -swift-version 5 \
  -framework Cocoa -framework Carbon -framework ScreenCaptureKit -framework CoreImage \
  *.swift -o "$APP/Contents/MacOS/TrainingHelper"
cp Info.plist "$APP/Contents/Info.plist"

if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  echo "WARNING: certificate '$IDENTITY' not found - using an ad-hoc signature."
  echo "         macOS will ask for the permissions again after every build. See SETUP.txt."
  codesign --force --deep --sign - "$APP"
fi

echo "Built $APP  ->  open it with:  open $APP"
