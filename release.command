#!/bin/zsh
# Publishes a new version of Swapdeck (切号). Everyone who has it installed is offered the update.
#
#   ./release.command 1.1.1 "这次改了什么"
#
# Steps: bump the version, build, sign the zip with the Sparkle key, commit the version, create the GitHub
# release with the zip, then publish the new appcast entry (last, so the feed never points at a missing file).
set -e
setopt null_glob
cd "${0:A:h}"

VERSION="$1"; NOTES="${2:-}"
[[ -n "$VERSION" ]] || { echo "用法：./release.command <版本号，如 1.1.1> \"更新说明\""; exit 1; }
REPO=lazymicezhu/Swapdeck
KEY="$HOME/Library/Application Support/Swapdeck-release/sparkle_ed25519.key"
[[ -f "$KEY" ]] || { echo "找不到签名私钥：$KEY"; exit 1; }

# Commits must be the owner's own identity.
[[ "$(git config user.name)" == "Lazymice" && "$(git config user.email)" == "130998159+lazymicezhu@users.noreply.github.com" ]] \
  || { echo "git 身份不是 Lazymice <130998159+lazymicezhu@users.noreply.github.com>，已停止。"; exit 1; }
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || { echo "请在 main 分支发版。"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "还有未提交的改动，先提交再发版。"; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION 已存在。"; exit 1; }

PLIST=App/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $PLIST) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" $PLIST

zsh build.command
ZIP="Swapdeck-$VERSION.zip"
SIG=$(Vendor/bin/sign_update --ed-key-file "$KEY" "$ZIP")   # sparkle:edSignature="…" length="…"

git add $PLIST
git commit -q -m "Release $VERSION"
git push -q origin main

# GitHub API with the token git already uses for this Mac (never printed).
TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill | sed -n 's/^password=//p')
AUTH=$(mktemp); chmod 600 "$AUTH"; trap 'rm -f "$AUTH"' EXIT
print -r -- "header = \"Authorization: Bearer $TOKEN\"" > "$AUTH"
BODY=$(python3 -c 'import json,sys; print(json.dumps({"tag_name":"v"+sys.argv[1],"target_commitish":"main","name":"切号 "+sys.argv[1],"body":sys.argv[2] or "更新"}))' "$VERSION" "$NOTES")
UPLOAD=$(curl -sf -K "$AUTH" -H "Accept: application/vnd.github+json" -d "$BODY" "https://api.github.com/repos/$REPO/releases" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["upload_url"].split("{")[0])')
curl -sf -K "$AUTH" -H "Content-Type: application/zip" --data-binary @"$ZIP" "$UPLOAD?name=$ZIP" >/dev/null
URL="https://github.com/$REPO/releases/download/v$VERSION/$ZIP"

# Newest entry first; older ones stay so anyone can still read the history.
python3 - "$VERSION" "$BUILD" "$URL" "$SIG" "$NOTES" <<'PY'
import sys, html, os, email.utils
version, build, url, sig, notes = sys.argv[1:]
item = f"""    <item>
      <title>{version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>{html.escape(notes or "更新").replace(chr(10), "<br>")}</p>]]></description>
      <enclosure url="{url}" type="application/octet-stream" {sig} />
    </item>
"""
path = "appcast.xml"
if not os.path.exists(path):
    open(path, "w").write('<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n  <channel>\n    <title>Swapdeck</title>\n  </channel>\n</rss>\n')
text = open(path).read()
marker = "    <title>Swapdeck</title>\n"
text = text.replace(marker, marker + item, 1)
open(path, "w").write(text)
PY
git add appcast.xml
git commit -q -m "Publish $VERSION in appcast"
git push -q origin main
echo "已发布 $VERSION：$URL"
echo "已安装的用户会在 6 小时内收到更新提示，或在「检查更新…」里立即看到。"
