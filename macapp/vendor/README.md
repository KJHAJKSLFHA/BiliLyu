# 把 ffmpeg 放这里

`build.sh` 需要 `macapp/vendor/ffmpeg`，它是一个静态链接的 macOS arm64 ffmpeg。

仓库里**没有**包含它（43 MB，且是 GPL 构建），按根目录 README 的命令下载即可：

```bash
curl -L -o macapp/vendor/ffmpeg \
  https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64
chmod +x macapp/vendor/ffmpeg
```
