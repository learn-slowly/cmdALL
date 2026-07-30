#!/bin/bash
# hwp-convert(구형 .hwp 원본 그대로 보기용, MIT)를 npm에서 받아 브라우저용 단일 파일로 묶어
# Sources/Resources/web/hwpconvert/에 반영한다(버전 갱신 시 재실행).
#
# hwp-convert는 이미 공식 브라우저 ESM 번들(dist/browser/hwp-convert.browser.mjs)을 낸다 —
# hwp.js 때처럼 Node 전용 모듈을 stub할 필요가 없다. 다만 cmd-docu의 다른 로컬 자산
# (katex/mermaid/luxon 등)과 로딩 방식을 맞추려고 ESM(import/export)이 아니라 평범한
# <script> 인라인 주입이 가능한 IIFE(전역 window.HWPCONVERT)로 한 번 더 묶는다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
npm init -y >/dev/null 2>&1
npm install hwp-convert@1 --silent

cat > entry.mjs <<'EOF'
export { hwpToHwpx, HwpxReader } from "hwp-convert/browser";
EOF

npx --yes esbuild entry.mjs --bundle --platform=browser --format=iife \
  --global-name=HWPCONVERT --outfile=hwpconvert.bundle.js

DEST="$ROOT/Sources/Resources/web/hwpconvert"
mkdir -p "$DEST"
cp hwpconvert.bundle.js "$DEST/"

VERSION="$(node -p "require('./node_modules/hwp-convert/package.json').version")"
grep -v '^hwp-convert ' "$ROOT/Sources/Resources/web/VERSIONS.txt" > "$ROOT/Sources/Resources/web/VERSIONS.txt.tmp" || true
mv "$ROOT/Sources/Resources/web/VERSIONS.txt.tmp" "$ROOT/Sources/Resources/web/VERSIONS.txt"
echo "hwp-convert $VERSION (esbuild IIFE re-bundle of official browser ESM build)" >> "$ROOT/Sources/Resources/web/VERSIONS.txt"

echo "완료: $DEST/hwpconvert.bundle.js"
