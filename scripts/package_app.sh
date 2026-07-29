#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 앱 번들 이름(겉면)과 실행파일 이름(내부 식별자)을 분리한다.
# 실행파일·CFBundleExecutable은 CmdMD 유지 — 데이터 디렉터리(Application
# Support/CmdMD)·업스트림 머지와 얽힌 내부 이름은 바꾸지 않는다(스펙 §1).
BUNDLE_NAME="cmdALL"
EXECUTABLE_NAME="CmdMD"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$BUNDLE_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/$EXECUTABLE_NAME"
PLIST="$CONTENTS_DIR/Info.plist"
APP_ICON="$ROOT_DIR/Resources/AppIcon.icns"
ZIP_FILE="$DIST_DIR/$BUNDLE_NAME-macos.zip"

echo "Building $BUNDLE_NAME release..."
BUILD_BIN_DIR="$(swift build --configuration release --show-bin-path)"
swift build --configuration release

BUILT_EXECUTABLE="$BUILD_BIN_DIR/$EXECUTABLE_NAME"
if [[ ! -x "$BUILT_EXECUTABLE" ]]; then
  echo "Release executable not found: $BUILT_EXECUTABLE" >&2
  exit 1
fi

rm -rf "$APP_DIR" "$ZIP_FILE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILT_EXECUTABLE" "$EXECUTABLE"
chmod 755 "$EXECUTABLE"

# SwiftPM resource bundles (e.g. Highlightr_Highlightr.bundle — highlight.js +
# CSS themes). Without these, Highlightr's `Bundle.module` accessor traps on the
# first code-block highlight and the app crashes on launch (the 1.4.6
# regression). Copy every generated *.bundle into Contents/Resources so
# `Bundle.module` resolves them via `Bundle.main.resourceURL`.
shopt -s nullglob
resource_bundles=("$BUILD_BIN_DIR"/*.bundle)
shopt -u nullglob
if [[ ${#resource_bundles[@]} -eq 0 ]]; then
  echo "Warning: no SwiftPM resource bundles found in $BUILD_BIN_DIR; code highlighting may be unavailable." >&2
fi
for bundle in "${resource_bundles[@]}"; do
  echo "Bundling resource: $(basename "$bundle")"
  cp -R "$bundle" "$RESOURCES_DIR/"
done

# The copy above is necessary but NOT sufficient. With `swift build`, Highlightr's
# generated `Bundle.module` accessor resolves the bundle from `Bundle.main.bundleURL`
# (the .app ROOT, where code signing forbids resources) and from a baked `.build` path
# (absent on user machines) — it never checks Contents/Resources. So the app still traps
# on the first code-block highlight (editor render). Repoint the baked fallback path to
# the shipped Contents/Resources bundle, before codesign re-seals the binary.
# See FIX_FOR_CLAUDE_CODE.md. Long-term fix: build via an Xcode/xcodebuild app target.
if command -v python3 >/dev/null 2>&1; then
  python3 "$(dirname "$0")/fix-highlightr-bundle.py" "$EXECUTABLE" \
    || echo "Warning: Highlightr bundle-path patch failed; editor view may still crash." >&2
else
  echo "Warning: python3 not found; skipping Highlightr bundle-path patch." >&2
fi

if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"
else
  echo "Warning: $APP_ICON not found; bundling without an app icon." >&2
fi

# Brand book glyph used by in-app logo (Welcome / Onboarding heroes).
BOOK_GLYPH="$ROOT_DIR/Resources/cmds-book-white.png"
if [[ -f "$BOOK_GLYPH" ]]; then
  cp "$BOOK_GLYPH" "$RESOURCES_DIR/cmds-book-white.png"
fi

cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>cmdALL</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>md</string>
        <string>markdown</string>
        <string>mdown</string>
        <string>txt</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>Markdown Document</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
        <string>public.plain-text</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>hwp</string>
        <string>hwpx</string>
        <string>hwpml</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>Hangul Document</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
    </dict>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>doc</string>
        <string>docx</string>
        <string>xls</string>
        <string>xlsx</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>Office Document</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
    </dict>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>pdf</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>PDF Document</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.adobe.pdf</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>png</string>
        <string>jpg</string>
        <string>jpeg</string>
        <string>heic</string>
        <string>webp</string>
        <string>gif</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>Image</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
    </dict>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>mp3</string>
        <string>m4a</string>
        <string>aac</string>
        <string>wav</string>
        <string>aiff</string>
        <string>flac</string>
        <string>mp4</string>
        <string>mov</string>
        <string>m4v</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>Media</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
    </dict>
  </array>
  <key>CFBundleExecutable</key>
  <string>CmdMD</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>work.cmdspace.cmddocu</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>cmdALL</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.9.417</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>work.cmdspace.cmddocu</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>cmdmd</string>
      </array>
    </dict>
  </array>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# 소유자 쓰기 권한 부여 — SwiftPM 체크아웃에서 온 리소스(Highlightr 번들의 *.css 등)가
# 0444로 들어와 그대로 배포되면, 받는 사람이 README대로 격리 해제를 해도
# `xattr -dr com.apple.quarantine`이 Permission denied로 실패하고 **앱 본체의 격리
# 표시가 남아 계속 차단된다**(실측 재현: dmg·zip 양쪽 동일, 잔존 1개).
# 서명 전에 모드만 바꾸므로 codesign 결과는 영향 없다(chmod 후 서명 유효 실측).
chmod -R u+w "$APP_DIR"

# 서명 — 예전엔 순수 ad-hoc(--sign -)이었는데, 이 방식은 빌드마다 CDHash(내용 해시)가
# 바뀌어 "손쉬운 사용" 권한이 매 재빌드마다 깨지는 구조적 문제가 있었다(2026-07-27·29
# 재발 확인). 이 컴퓨터 전용 고정 인증서("cmdALL Local Dev", 로그인 키체인에 로컬 생성 —
# 애플 발급 아님, 이 컴퓨터에서만 통용)로 서명하면 designated requirement가 "인증서
# 지문" 기준으로 고정돼(`codesign -d -r-`로 확인 가능) 재빌드해도 안 바뀐다. 인증서가
# 없는 다른 컴퓨터(배포용 빌드)에서는 자동으로 ad-hoc 폴백.
CODESIGN_IDENTITY="cmdALL Local Dev"
if command -v codesign >/dev/null 2>&1; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CODESIGN_IDENTITY"; then
    echo "Signing $BUNDLE_NAME.app with local fixed identity ($CODESIGN_IDENTITY)..."
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR"
  else
    echo "Local identity not found — falling back to ad-hoc signing $BUNDLE_NAME.app..."
    codesign --force --deep --sign - "$APP_DIR"
  fi
  codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
else
  echo "codesign not found; leaving $BUNDLE_NAME.app unsigned."
fi

(
  cd "$DIST_DIR"
  zip -qry -X "$(basename "$ZIP_FILE")" "$BUNDLE_NAME.app"
)

echo "Created $ZIP_FILE"
