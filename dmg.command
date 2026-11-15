#!/bin/zsh
# Packs the installed /Applications/Swapdeck.app into Swapdeck-<version>.dmg: the classic install window with the
# app on the left, 应用程序 on the right, and how to get past "无法验证" below (dmg/background*.png, drawn from
# dmg/background.html). Run build.command first; release.command runs both.
set -e
cd "${0:A:h}"
APP=/Applications/Swapdeck.app
[[ -d "$APP" ]] || { echo "先运行 build.command"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
VOL="切号"
WORK="${TMPDIR:-/tmp}/swapdeck-dmg"
DMG="Swapdeck-$VERSION.dmg"

hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
rm -rf "$WORK"; mkdir -p "$WORK/stage/.background"
ditto "$APP" "$WORK/stage/Swapdeck.app"
ln -s /Applications "$WORK/stage/Applications"
tiffutil -cathidpicheck dmg/background.png dmg/background@2x.png -out "$WORK/stage/.background/background.tiff" >/dev/null 2>&1

hdiutil create -quiet -srcfolder "$WORK/stage" -volname "$VOL" -fs HFS+ -format UDRW -size 60m "$WORK/rw.dmg"
hdiutil attach -quiet -noautoopen "$WORK/rw.dmg"
# Finder lays out the window and stores it in the volume's .DS_Store.
osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    delay 2
    tell container window
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      set the bounds to {200, 120, 860, 598}
    end tell
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 100
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Swapdeck.app" of container window to {180, 150}
    set position of item "Applications" of container window to {480, 150}
    update without registering applications
    delay 2
    close
    -- Reopen once so Finder writes the hidden toolbar and the size into .DS_Store.
    open
    delay 2
    tell container window
      set toolbar visible to false
      set statusbar visible to false
      set the bounds to {200, 120, 860, 598}
    end tell
    delay 2
    close
  end tell
end tell
OSA
sync
hdiutil detach -quiet "/Volumes/$VOL"
rm -f ./*.dmg(N)
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$WORK"
echo "完成：$(pwd)/$DMG"
