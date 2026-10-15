#!/usr/bin/env bash
# Release files in build/: Loquor-<version>[-offline].zip and .dmg.
#   --bundle-model  offline build with the speech model inside (see build-app.sh)
#
# With a "Developer ID Application" identity and LOQUOR_NOTARY_PROFILE set (a
# profile saved with `xcrun notarytool store-credentials`), the app and the DMG
# are notarized and stapled, so they open without Gatekeeper warnings.
set -euo pipefail
cd "$(dirname "$0")/.."
for arg in "$@"; do
  [[ $arg == --bundle-model ]] || { echo "usage: $0 [--bundle-model]" >&2; exit 2; }
done
scripts/build-app.sh "$@"

version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
suffix=""; [[ " $* " == *" --bundle-model "* ]] && suffix="-offline"
name="Loquor-$version$suffix"
authority=$(codesign -dvv build/Loquor.app 2>&1 | sed -n 's/^Authority=//p' | head -1)
notarize=false
if [[ $authority == Developer\ ID* && -n ${LOQUOR_NOTARY_PROFILE:-} ]]; then
  notarize=true
elif [[ $authority == Developer\ ID* ]]; then
  echo "note: signed with Developer ID but LOQUOR_NOTARY_PROFILE isn't set, so not notarized" >&2
fi

# The app plus LICENSE and NOTICE (the model's CC BY 4.0 credit travels with it).
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
mkdir "$stage/$name"
cp -R build/Loquor.app "$stage/$name/"

if $notarize; then
  echo "Notarizing the app (a few minutes)…"
  ditto -c -k --norsrc --keepParent "$stage/$name/Loquor.app" "$stage/notarize.zip"
  xcrun notarytool submit "$stage/notarize.zip" --keychain-profile "$LOQUOR_NOTARY_PROFILE" --wait
  xcrun stapler staple "$stage/$name/Loquor.app"
fi
cp LICENSE NOTICE "$stage/$name/"
# Extended attributes (provenance, quarantine) would become ._ files in the zip;
# the app's signature doesn't depend on them.
xattr -cr "$stage/$name"

rm -f "build/$name.zip" "build/$name.dmg"
ditto -c -k --norsrc --keepParent "$stage/$name" "build/$name.zip"

# DMG: the usual drag-to-Applications window. Only the app and an Applications
# link (LICENSE and NOTICE are inside the app). Finder lays out the window; the
# first run may ask to let the terminal control Finder.
dmgsrc="$stage/dmg"
mkdir -p "$dmgsrc/.background"
cp -R "$stage/$name/Loquor.app" "$dmgsrc/"
ln -s /Applications "$dmgsrc/Applications"
cp Resources/dmg-background.tiff "$dmgsrc/.background/background.tiff"
cp Resources/AppIcon.icns "$dmgsrc/.VolumeIcon.icns"

volume="Loquor $version"
hdiutil detach "/Volumes/$volume" -quiet 2>/dev/null || true
hdiutil create -quiet -volname "$volume" -srcfolder "$dmgsrc" -fs HFS+ -format UDRW -ov "$stage/rw.dmg"
mount=$(hdiutil attach -readwrite -noverify -noautoopen "$stage/rw.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')
[[ -x /usr/bin/SetFile ]] && /usr/bin/SetFile -a C "$mount"   # use .VolumeIcon.icns
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$volume"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 520}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Loquor.app" of container window to {165, 190}
    set position of item "Applications" of container window to {495, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
chmod -Rf go-w "$mount" 2>/dev/null || true
sync
hdiutil detach "$mount" -quiet
hdiutil convert -quiet "$stage/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "build/$name.dmg"
if [[ $authority == Developer\ ID* ]]; then
  codesign --force --sign "$authority" --timestamp "build/$name.dmg"
fi
if $notarize; then
  echo "Notarizing the DMG…"
  xcrun notarytool submit "build/$name.dmg" --keychain-profile "$LOQUOR_NOTARY_PROFILE" --wait
  xcrun stapler staple "build/$name.dmg"
fi

ls -lh "build/$name.zip" "build/$name.dmg" | awk '{print $5, $9}'
$notarize && echo "Notarized and stapled." || echo "Not notarized: Gatekeeper will ask users to approve it (docs/releasing.md)."
