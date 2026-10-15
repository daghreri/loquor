#!/usr/bin/env bash
# Build Loquor.app into build/.
#   --bundle-model  ship the speech model inside the app (offline build, ~450 MB);
#                   otherwise the app downloads it once on first launch (~11 MB app)
#   --install       copy to /Applications and relaunch it there (permissions and
#                   start-at-login belong to that copy)
#
# Signing, first match wins:
#   $LOQUOR_SIGN_IDENTITY       an identity name or SHA-1 you choose
#   "Developer ID Application"  for releases (see docs/releasing.md)
#   "Loquor Dev"                local self-signed identity (scripts/make-dev-cert.sh)
#   ad-hoc                      macOS forgets permissions after every rebuild
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Loquor.app
MODEL=parakeet-tdt-0.6b-v2
MODEL_SRC="$HOME/Library/Application Support/Loquor/Models/$MODEL"

bundle_model=false install=false
for arg in "$@"; do
  case $arg in
    --bundle-model) bundle_model=true ;;
    --install) install=true ;;
    *) echo "usage: $0 [--bundle-model] [--install]" >&2; exit 2 ;;
  esac
done

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Loquor "$APP/Contents/MacOS/Loquor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # redraw with: swift scripts/make-icon.swift
# Package resource bundles (FluidAudio's), licenses and notices.
for bundle in .build/release/*.bundle; do
  [[ -e $bundle ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done
cp LICENSE NOTICE "$APP/Contents/Resources/"
cp -R licenses "$APP/Contents/Resources/"
chmod -R u+w "$APP"   # SwiftPM checkouts are read-only; copies must be writable

if $bundle_model; then
  # The copy the app downloaded and verified against the pinned commit (ModelStore.swift).
  if [[ ! -s $MODEL_SRC/.fluidaudio-revision ]]; then
    echo "error: no verified model in $MODEL_SRC; run Loquor once so it downloads it" >&2
    exit 1
  fi
  mkdir -p "$APP/Contents/Resources/Models"
  ditto "$MODEL_SRC" "$APP/Contents/Resources/Models/$MODEL"
  echo "Bundled the speech model ($(du -sh "$APP/Contents/Resources/Models" | cut -f1))"
fi

identity=${LOQUOR_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    identity=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
  elif security find-certificate -c "Loquor Dev" >/dev/null 2>&1; then
    identity="Loquor Dev"
  else
    identity="-"
    echo "note: ad-hoc signing; macOS will forget permissions after each rebuild (run scripts/make-dev-cert.sh)" >&2
  fi
fi
timestamp=()
[[ $identity == Developer\ ID* ]] && timestamp=(--timestamp)  # required for notarization
codesign --force --sign "$identity" --options runtime ${timestamp[@]+"${timestamp[@]}"} \
  --entitlements Resources/Loquor.entitlements "$APP"
echo "Built $APP (signed: $identity, $(du -sh "$APP" | cut -f1))"

if $install; then
  pkill -x Loquor 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/Loquor.app
  cp -R "$APP" /Applications/
  open /Applications/Loquor.app
  echo "Installed and launched /Applications/Loquor.app"
fi
