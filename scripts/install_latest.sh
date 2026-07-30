#!/bin/bash
#
# cmdALL 최신 릴리스 설치 스크립트 (맥미니·맥북 공용)
#
# 왜 이 스크립트인가:
#   cmdALL은 adhoc 서명(Apple 공증 안 함)이라, 브라우저·AirDrop·메시지로 받으면
#   macOS Gatekeeper가 격리(com.apple.quarantine) 속성을 붙여
#   "Apple이 악성 코드 없음을 확인할 수 없습니다" 경고로 실행을 막는다.
#   반면 curl로 받은 파일에는 격리 속성이 붙지 않는다. 이 스크립트는 최신 릴리스를
#   curl로 받아 설치하므로 그 경고가 뜨지 않는다. 소스·Xcode 없이 어느 맥에서든 동작.
#
# 사용법:  ./scripts/install_latest.sh
#   (레포 없이 스크립트만 있어도 동작. /Applications 쓰기 권한 없으면 앞에 sudo)
#
set -euo pipefail

REPO="learn-slowly/cmdALL"
APP="cmdALL.app"
DEST="/Applications"
ZIP_URL="https://github.com/$REPO/releases/latest/download/cmdALL-macos.zip"
SUMS_URL="https://github.com/$REPO/releases/latest/download/SHA256SUMS.txt"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ 최신 릴리스 내려받는 중…"
curl -fL --progress-bar -o "$TMP/cmdALL-macos.zip" "$ZIP_URL"

# 무결성 검증 (SHA256SUMS.txt가 있으면)
if curl -fsL -o "$TMP/SHA256SUMS.txt" "$SUMS_URL"; then
  EXPECTED="$(grep 'cmdALL-macos.zip' "$TMP/SHA256SUMS.txt" | awk '{print $1}')"
  ACTUAL="$(shasum -a 256 "$TMP/cmdALL-macos.zip" | awk '{print $1}')"
  if [ -n "$EXPECTED" ] && [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "✗ 체크섬 불일치 — 설치 중단"
    echo "  기대: $EXPECTED"
    echo "  실제: $ACTUAL"
    exit 1
  fi
  echo "  ✓ 체크섬 일치"
fi

echo "▸ 압축 해제 중…"
ditto -x -k "$TMP/cmdALL-macos.zip" "$TMP/unpacked"
STAGED="$TMP/unpacked/$APP"
[ -d "$STAGED" ] || { echo "✗ zip 안에서 $APP 을(를) 찾지 못함"; exit 1; }

# 이 컴퓨터 전용 고정 인증서("cmdALL Local Dev")가 로그인 키체인에 있으면 그걸로
# 재서명한다 — GitHub Release는 ad-hoc 서명이라 그대로 설치하면 빌드마다 CDHash가
# 바뀌어 "손쉬운 사용" 권한이 재발한다(package_app.sh와 동일 로직, 2026-07-30 실측).
# 인증서가 없는 다른 컴퓨터에서는 조용히 건너뛰고 ad-hoc 그대로 둔다.
# 재서명은 보안 통제가 아니라 편의 최적화라(체크섬 검증은 이미 위에서 끝남) 실패해도
# 설치 자체를 막지 않는다 — 다만 성공했다면 반드시 재검증해 서명이 섞인 채 남는 사고를
# 막는다. 또한 /Applications의 실물이 아니라 압축 해제한 임시 폴더(스테이징)에서
# 서명·검증까지 전부 끝낸 뒤에야 옮긴다 — 재서명이 실패해도 기존 설치본이 절대
# 중간 상태로 남지 않는다(2026-07-30 opus 자문 S3).
#
# 서명 전에 격리 속성 제거 + 쓰기 권한 확보(SwiftPM 리소스가 0444로 배포돼 재서명이
# 실패하는 전례가 있었다). `--deep`은 Apple이 배포용 서명에 권장하지 않는 옵션이다
# (중첩 코드의 기존 entitlements·requirement를 전부 버리고 덮어쓴다) — 지금은 이 앱에
# 커스텀 entitlements가 없어 안전하지만, 나중에 하나라도 추가하면 `--entitlements`를
# 반드시 같이 지정해야 한다(안 그러면 조용히 사라진다).
xattr -cr "$STAGED" 2>/dev/null || true
chmod -R u+w "$STAGED" 2>/dev/null || true

CODESIGN_IDENTITY_NAME="cmdALL Local Dev"
# 이름 대신 SHA-1 지문으로 서명한다 — 인증서를 재발급해 동명 인증서가 두 개 이상
# 생기면(정상적인 결말) 이름 substring 매칭은 `ambiguous(matches multiple identities)`로
# 실패하지만, 지문은 항상 하나의 인증서만 정확히 가리킨다(2026-07-30 opus 자문 S2).
CODESIGN_HASH=""
if command -v codesign >/dev/null 2>&1; then
  CODESIGN_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "\"$CODESIGN_IDENTITY_NAME\"" | head -1 | awk '{print $2}')" || true
fi

if [ -n "$CODESIGN_HASH" ]; then
  echo "▸ 로컬 고정 인증서로 재서명 중… (손쉬운 사용 권한 재발 방지)"
  if codesign --force --deep --sign "$CODESIGN_HASH" "$STAGED"; then
    if ! codesign --verify --deep --strict "$STAGED" 2>&1; then
      echo "⚠ 재서명 후 확인 실패 — 이번엔 손쉬운 사용 권한을 다시 허용해야 할 수 있습니다."
    fi
  else
    echo "⚠ 재서명 실패 — 설치는 계속 진행합니다(권한을 다시 허용해야 할 수 있습니다)."
  fi
fi

# 실행 중이면 종료
if pgrep -f "$DEST/$APP/Contents/MacOS/" >/dev/null 2>&1; then
  echo "▸ 실행 중인 cmdALL 종료…"
  osascript -e 'quit app "cmdALL"' 2>/dev/null || true
  sleep 1
fi

echo "▸ 설치 중… ($DEST/$APP)"
rm -rf "$DEST/$APP"
cp -R "$STAGED" "$DEST/"

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
QCNT="$(find "$DEST/$APP" -xattrname com.apple.quarantine 2>/dev/null | wc -l | tr -d ' ')"
echo "✓ 설치 완료 — cmdALL ${VER}  (격리 파일 ${QCNT}개)"
echo "  실행: open \"$DEST/$APP\""
