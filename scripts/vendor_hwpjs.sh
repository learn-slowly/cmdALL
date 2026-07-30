#!/bin/bash
# hwp.js(구형 .hwp 원본 조판 렌더용, Apache-2.0)를 npm에서 받아 브라우저용 단일 파일로 묶어
# Sources/Resources/web/hwpjs/에 반영한다(버전 갱신 시 재실행).
#
# hwp.js의 npm 배포판(build/esm.js)은 최상단에서 Node 전용 모듈 `fs`를 무조건 import한다
# (WKWebView 안에는 없는 모듈) — 실제로는 브라우저 경로에서 안 쓰이므로 esbuild가 그 자리에
# 빈 모듈을 넣도록(alias) 해서 우회한다. 실제 파일 읽기(new Viewer(container, data))는 그대로 동작.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
npm init -y >/dev/null 2>&1
npm install hwp.js@0.0.3 --silent

cat > entry.mjs <<'EOF'
import { parse, Viewer } from 'hwp.js';
window.HWPJS = { parse, Viewer };
EOF
echo "export default {};" > empty-fs.mjs

npx --yes esbuild entry.mjs --bundle --platform=browser --format=iife \
  --alias:fs=./empty-fs.mjs --outfile=hwpjs.bundle.js

DEST="$ROOT/Sources/Resources/web/hwpjs"
mkdir -p "$DEST"
cp hwpjs.bundle.js "$DEST/"

VERSION="$(node -p "require('./node_modules/hwp.js/package.json').version")"
grep -v '^hwp.js ' "$ROOT/Sources/Resources/web/VERSIONS.txt" > "$ROOT/Sources/Resources/web/VERSIONS.txt.tmp" || true
mv "$ROOT/Sources/Resources/web/VERSIONS.txt.tmp" "$ROOT/Sources/Resources/web/VERSIONS.txt"
echo "hwp.js $VERSION (esbuild bundle, fs stubbed)" >> "$ROOT/Sources/Resources/web/VERSIONS.txt"

echo "완료: $DEST/hwpjs.bundle.js"
