#!/bin/zsh
# Builds Swapdeck.app (切号) and installs it as the only copy, in /Applications. No Xcode project needed.
# Also writes Swapdeck-<version>.zip next to this script, for sharing and for release.command.
set -e
setopt null_glob
cd "${0:A:h}"
NAME=Swapdeck
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" App/Info.plist)
OUT="${TMPDIR:-/tmp}/swapdeck-build"
APP="$OUT/$NAME.app"

# Sparkle (auto-update), pinned and checked, kept out of git.
SPARKLE_VERSION=2.10.1
SPARKLE_SHA=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
if [[ ! -d Vendor/Sparkle.framework ]]; then
  mkdir -p Vendor
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o Vendor/sparkle.tar.xz
  echo "$SPARKLE_SHA  Vendor/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
  tar -xf Vendor/sparkle.tar.xz -C Vendor Sparkle.framework bin
  rm Vendor/sparkle.tar.xz
fi

rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
# Universal binary (Apple silicon + Intel), macOS 15+.
for ARCH in arm64 x86_64; do
  swiftc -O -disable-sandbox -module-cache-path "$OUT/ModuleCache-$ARCH" -parse-as-library -target "$ARCH-apple-macos15.0" -swift-version 5 \
    -F Vendor -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -module-name Swapdeck App/*.swift -o "$OUT/$NAME-$ARCH"
done
lipo -create "$OUT/$NAME-arm64" "$OUT/$NAME-x86_64" -output "$APP/Contents/MacOS/$NAME"
cp App/Info.plist "$APP/Contents/Info.plist"
cp -R App/Resources/*.lproj "$APP/Contents/Resources/"
cp App/Resources/*Template*.png "$APP/Contents/Resources/"  # menu bar logos
ditto --norsrc --noextattr Vendor/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
# The XPC services are only for sandboxed apps.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

ICONSET="$OUT/AppIcon.iconset"; mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z $SIZE $SIZE App/Resources/icon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  sips -z $((SIZE*2)) $((SIZE*2)) App/Resources/icon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$OUT"/ModuleCache-* "$OUT/$NAME-arm64" "$OUT/$NAME-x86_64"

xattr -cr "$APP"  # iCloud adds Finder info, which codesign refuses
# Ad-hoc signature, inside out: Sparkle's helpers, the framework, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign - "$FW/Autoupdate"
codesign --force --sign - "$FW/Updater.app"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

# Share / release archive (ditto keeps the framework's symlinks).
rm -f ./*.zip
ditto -c -k --keepParent --norsrc --noextattr "$APP" "./$NAME-$VERSION.zip"

# Only one copy on this Mac: replace the installed app (and the pre-1.1 切号.app), drop the temp build.
for OLD in com.lazymice.swapdeck com.lazymice.qiehao; do osascript -e "quit app id \"$OLD\"" >/dev/null 2>&1 || true; done
while pgrep -f "/Contents/MacOS/(Swapdeck|QieHao)" >/dev/null; do sleep 0.3; done
rm -rf "/Applications/$NAME.app" "/Applications/切号.app"
ditto "$APP" "/Applications/$NAME.app"
rm -rf "$OUT"
echo "完成：/Applications/$NAME.app（$VERSION）  分享：$(pwd)/$NAME-$VERSION.zip"
