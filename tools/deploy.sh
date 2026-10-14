#!/bin/bash
# 重新部署网站到 Netlify（vconverter.netlify.app）
#
# 结构：index.html 是介绍页，app/ 里才是转换界面（和 EchoLingo 一样）。
set -e
cd "$(dirname "$0")/.." || exit 1

NCLI_HOME="/Users/orion/WorkBuddy/2026-10-12-11-40-26/english-video-reader/desktop/.tools/ncli/.home"
NTL="/Users/orion/WorkBuddy/2026-10-12-11-40-26/english-video-reader/desktop/.tools/ncli/node_modules/.bin/netlify"

export HOME="$NCLI_HOME"
export PATH="/Users/orion/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/node/bin:$PATH"

echo "== 1) 拼装部署目录 =="
rm -rf .deploy
mkdir -p .deploy/app/vendor
cp index.html .deploy/
cp app/index.html .deploy/app/
# 引擎只在 app/ 下用，避免传两份 23MB 的 wasm
cp app/vendor/*.js app/vendor/*.wasm .deploy/app/vendor/

cat > .deploy/_headers <<'HDR'
/app/vendor/ffmpeg-core.wasm
  Content-Type: application/wasm
  Cache-Control: public, max-age=31536000, immutable

/app/vendor/*
  Cache-Control: public, max-age=31536000, immutable

/index.html
  Cache-Control: public, max-age=0, must-revalidate

/app/index.html
  Cache-Control: public, max-age=0, must-revalidate
HDR
echo "   $(find .deploy -type f | wc -l | tr -d ' ') 个文件，$(du -sh .deploy | cut -f1)"

echo "== 2) 上传 =="
"$NTL" deploy --dir=.deploy --prod

echo
echo "== 3) 核验 =="
curl -s -o /dev/null -w "  介绍页 /            %{http_code}\n" https://vconverter.netlify.app/
curl -s -o /dev/null -w "  转换页 /app/        %{http_code}\n" https://vconverter.netlify.app/app/
curl -s -o /dev/null -w "  wasm 引擎           %{http_code}  %{content_type}\n" https://vconverter.netlify.app/app/vendor/ffmpeg-core.wasm
