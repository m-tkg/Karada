#!/bin/bash
# OTA（Over-The-Air）配布用の ipa + manifest.plist + index.html を作り、
# ota.mtkg（miscpi.mtkg の /mnt/storage/ota）へ ssh 経由で配信する。
#
# 使い方:
#   ./Scripts/ota.sh                       # https://ota.mtkg 向けに作って配信
#   ./Scripts/ota.sh https://example.com   # 別サーバ向けに作って配信
#   ./Scripts/ota.sh --no-deploy           # build/ota/ に作るだけ（配信しない）
#
# 生成物は build/ota/ に置く:
#   Karada.ipa / manifest.plist / index.html / icon57.png / icon512.png
#
# 配信先（環境変数で上書き可）:
#   OTA_SSH_HOST=miscpi.mtkg  OTA_SSH_USER=masaki  OTA_REMOTE_DIR=/mnt/storage/ota/karada
#
# ota.mtkg は複数アプリの配布に使う共有サーバなので、
# /mnt/storage/ota 直下ではなく /mnt/storage/ota/karada に置く。

set -euo pipefail

DEPLOY=1
BASE_URL=""
for arg in "$@"; do
  case "$arg" in
    --no-deploy) DEPLOY=0 ;;
    https://*) BASE_URL="$arg" ;;
    *)
      echo "usage: $0 [https base url] [--no-deploy]" >&2
      exit 1
      ;;
  esac
done
BASE_URL="${BASE_URL:-https://ota.mtkg/karada}"
BASE_URL="${BASE_URL%/}"

DEPLOY_HOST="${OTA_SSH_HOST:-miscpi.mtkg}"
DEPLOY_USER="${OTA_SSH_USER:-masaki}"
DEPLOY_DIR="${OTA_REMOTE_DIR:-/mnt/storage/ota/karada}"

PROJECT=Karada.xcodeproj
SCHEME=Karada
OUT_DIR=build/ota
ARCHIVE_PATH="$OUT_DIR/Karada.xcarchive"
EXPORT_OPTIONS="$OUT_DIR/ExportOptions.plist"

mkdir -p "$OUT_DIR"

echo "==> xcodegen generate"
xcodegen generate

echo "==> archive"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  archive

echo "==> アイコン書き出し（manifest のインストール画面表示用）"
SRC_ICON="App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
sips -z 57 57 "$SRC_ICON" --out "$OUT_DIR/icon57.png" >/dev/null
sips -z 512 512 "$SRC_ICON" --out "$OUT_DIR/icon512.png" >/dev/null

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>ad-hoc</string>
    <key>teamID</key>
    <string>G72M73C546</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>manifest</key>
    <dict>
        <key>appURL</key>
        <string>${BASE_URL}/Karada.ipa</string>
        <key>displayImageURL</key>
        <string>${BASE_URL}/icon57.png</string>
        <key>fullSizeImageURL</key>
        <string>${BASE_URL}/icon512.png</string>
    </dict>
</dict>
</plist>
PLIST

echo "==> export（ipa + manifest.plist を生成）"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$OUT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates

cat > "$OUT_DIR/index.html" <<HTML
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Karada インストール</title>
</head>
<body style="font-family: -apple-system, sans-serif; text-align: center; padding-top: 4em;">
<h1>Karada</h1>
<p>
  <a href="itms-services://?action=download-manifest&url=${BASE_URL}/manifest.plist"
     style="display:inline-block; padding: 1em 2em; background:#007aff; color:#fff; text-decoration:none; border-radius:8px; font-size:1.2em;">
    インストール
  </a>
</p>
</body>
</html>
HTML

echo
echo "==> できた: $OUT_DIR"
echo "    Karada.ipa / manifest.plist / index.html / icon57.png / icon512.png"

if [ "$DEPLOY" -eq 0 ]; then
  echo "    --no-deploy 指定のため配信はスキップ（この5点を ${BASE_URL} 配下にアップロードすれば OTA できる）"
  exit 0
fi

echo "==> ${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_DIR} へ配信"
ssh "${DEPLOY_USER}@${DEPLOY_HOST}" "mkdir -p '${DEPLOY_DIR}'"
rsync -avz \
  "$OUT_DIR/Karada.ipa" \
  "$OUT_DIR/manifest.plist" \
  "$OUT_DIR/index.html" \
  "$OUT_DIR/icon57.png" \
  "$OUT_DIR/icon512.png" \
  "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_DIR}/"

echo
echo "==> 配信完了: ${BASE_URL}/index.html を iPhone のブラウザで開く"
