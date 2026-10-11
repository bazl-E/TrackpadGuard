#!/bin/zsh
# Builds TrackpadGuard.app into ./build. Pass --install to copy it to ~/Applications and launch it.
# Set SIGN_IDENTITY to a code signing identity (e.g. "Developer ID Application: ...") to keep
# the Accessibility permission across rebuilds; the default is an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/TrackpadGuard.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/TrackpadGuard"
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier io.github.bazl-e.trackpadguard "$APP"
echo "Built $APP"

# Optional: the diagnostic tool
swiftc -O tools/diagnose.swift -o build/diagnose && echo "Built build/diagnose"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x TrackpadGuard 2>/dev/null && sleep 1 || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/TrackpadGuard.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/TrackpadGuard.app
  echo "Installed to ~/Applications/TrackpadGuard.app"
fi
