#!/bin/bash
# 重新部署网站到 Netlify（vconverter.netlify.app）
#
# 为什么要拼 .deploy/ 目录：根目录里有 macapp/build（230MB 模块缓存）、
# dist/、.git 等本地东西，Netlify 只认 --dir 指向的那个目录。
set -e
cd "$(dirname "$0")/.." || exit 1

NCLI_HOME="/Users/orion/WorkBuddy/2026-10-12-11-40-26/english-video-reader/desktop/.tools/ncli/.home"
NTL="/Users/orion/WorkBuddy/2026-10-12-11-40-26/english-video-reader/desktop/.tools/ncli/node_modules/.bin/netlify"

export HOME="$NCLI_HOME"
export PATH="/Users/orion/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/node/bin:$PATH"

echo "== 1) 拼装部署目录 =="
rm -rf .deploy
mkdir -p .deploy/vendor
cp index.html .deploy/
cp vendor/ffmpeg.min.js vendor/ffmpeg-core.js vendor/ffmpeg-core.wasm \
   vendor/ffmpeg-core.worker.js .deploy/vendor/
cat > .deploy/_headers <<'HDR'
/vendor/ffmpeg-core.wasm
  Content-Type: application/wasm
  Cache-Control: public, max-age=31536000, immutable

/vendor/*
  Cache-Control: public, max-age=31536000, immutable

/index.html
  Cache-Control: public, max-age=0, must-revalidate
HDR
echo "   $(find .deploy -type f | wc -l | tr -d ' ') 个文件，$(du -sh .deploy | cut -f1)"

echo "== 2) 上传 =="
"$NTL" deploy --dir=.deploy --prod

echo
echo "== 3) 核验 =="
curl -s -o /dev/null -w "  首页        %{http_code}\n" https://vconverter.netlify.app/
curl -s -o /dev/null -w "  wasm 引擎   %{http_code}  %{content_type}\n" https://vconverter.netlify.app/vendor/ffmpeg-core.wasm
