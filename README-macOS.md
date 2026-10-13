# BiliLyu 视频转换器 · macOS 版

把浏览器里的视频转换网站打包成的原生 Mac 软件。**转换由内置的原生 ffmpeg 完成**，不是网页版的 WebAssembly。

- **应用位置**：`/Applications/BiliLyu 视频转换器.app`（工作区里另有一份 `dist/`）
- **体积**：约 67 MB（43 MB 是内置的静态 ffmpeg，24 MB 是作为后备的 wasm 内核）
- **系统要求**：macOS 13 及以上，Apple 芯片（arm64）

---

## 为什么从 wasm 换成原生 ffmpeg

网页版用 ffmpeg.wasm，工作方式是**把整个文件读进内存**，转换时内存里同时存在「输入 + 输出」两份。实测一个 B 站 4K 下载：

```
xxxxx-1-30120.m4s    6.8 GB   ← 4K H.264，2 小时 13 分
xxxxx-1-30280.m4s    145 MB
```

6.8 GB 在浏览器里根本放不下，所以**每个视频都转换失败**——这是架构上限，不是操作问题。

换成内置的原生 ffmpeg 之后：

| | ffmpeg.wasm | 原生 ffmpeg |
| --- | --- | --- |
| 内存占用 | 输入 + 输出全在内存 | 流式，几乎不占 |
| 文件大小上限 | 约 1.6 GB（实际更低） | 无上限 |
| 上面那个 6.8 GB 文件 | 必然失败 | **349 秒完成，7.4 GB 输出** |
| 转换后删除原文件 | 网页做不到 | **支持** |

B 站的 `.m4s` 在标准 MP4 前面多了 9 个字节（`000000000`），ffmpeg 直接读会报 `Invalid data found`。App 会把文件从第 9 字节开始**通过命名管道喂给 ffmpeg**，所以既不用先复制一份临时文件，也不需要可寻址输入，全程流式。

---

## 安装

```bash
./macapp/build.sh install     # 编译并安装到 /Applications
```

或者直接把 `dist/BiliLyu 视频转换器.app` 拖进「应用程序」。

> 本地临时签名（ad-hoc），自己机器上编译的不会有隔离属性，双击即可运行。

---

## 怎么用

1. 点「选择视频文件夹」选 B 站下载的文件夹（或直接把文件夹拖进窗口）。
2. 顶部「输出文件夹」指定保存位置——可以选外置硬盘。
3. 勾选视频 → 右下角「转换选中」。
4. 完成后 `文件 → 在访达中打开输出文件夹`（⇧⌘O）。

转换是**原质量无损**的（`-c copy` 只重新封装），不重新编码，所以画质不会掉。速度基本取决于磁盘：那个 6.8 GB 的文件用了约 6 分钟。

**注意**：「转换后删除原文件」是**永久删除**（和网页版的提示一致），只有转换成功的视频才会删，失败的会保留。

---

## 和网页版的差异

| 功能 | 网页版 | Mac 版 |
| --- | --- | --- |
| 转换引擎 | ffmpeg.wasm（受内存限制） | 内置原生 ffmpeg（流式，无上限） |
| 选择输出文件夹 | 浏览器弹窗 | 原生面板，选择会记住 |
| 转换后删除原文件 | 支持 | **支持**（原生删除） |
| 打开输出文件夹 | 无 | 菜单 ⇧⌘O |
| 界面语言 | 跟随浏览器 | 跟随系统语言，可随时切换 |

---

## 自己重新编译

需要 macOS 13+ / Apple 芯片，以及 Xcode Command Line Tools（提供 `swiftc`）。**不需要 Node、npm、Homebrew 或 Python 依赖。**

```bash
# 1) 取内置的 ffmpeg（约 43 MB，未随仓库分发，见下方「授权」）
curl -L -o macapp/vendor/ffmpeg \
  https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64
chmod +x macapp/vendor/ffmpeg

# 2) 构建
./macapp/build.sh                    # 编译出 dist/BiliLyu 视频转换器.app
./macapp/build.sh selftest           # 27 项内置自检
./macapp/build.sh install            # 编译并安装到 /Applications
```

App 图标是预置在 `macapp/icon/AppIcon.icns` 里的，**不装 Pillow 也能构建**；如果本机有带 Pillow 的 python3，`build.sh` 会自动重新生成图标（也可以 `PYTHON=/path/to/python3 ./macapp/build.sh` 指定）。

下面这段是原来的说明，保留作参考 —— 内置的 ffmpeg 需要放到 `macapp/vendor/ffmpeg`：

```bash
curl -L -o macapp/vendor/ffmpeg \
  https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64
chmod +x macapp/vendor/ffmpeg
```

改网页本身不用动 Swift：直接编辑根目录的 `index.html`，重新跑 `build.sh`，脚本会把 `index.html` 和 `vendor/` 一起复制进应用。

```
macapp/
├── build.sh              # 编译 + 打包 + 签名
├── src/main.swift        # WKWebView 宿主、菜单、桥、自检
├── src/Native.swift      # 原生 ffmpeg 转换、路径索引、拖拽捕获
├── icon/make_icon.py     # 生成 AppIcon.icns（可选，需要 Pillow）
├── icon/AppIcon.icns     # 预置图标，保证无依赖也能构建
└── vendor/ffmpeg         # 内置的静态 ffmpeg（自行下载，未入库）
```

---

## 自检

`./macapp/build.sh selftest` 在应用内真跑一遍完整链路，27 项全过才退出 0：

```
PASS | page origin                          | bililive://local | secure=true
PASS | language detection                   | navigator.language=zh-Hans-US lang=zh
PASS | blob Worker round trip
PASS | engine load / FS 读写 / lavfi 编码
PASS | remux -c copy + faststart            ← wasm 后备路径
PASS | 内置 ffmpeg 可用                     ← 原生引擎
PASS | 拖拽文件 URL 提取
PASS | save path triggered → file landed
PASS | 原生文件选择器回调被调用              ← 导入的关键
PASS | 选择文件夹 / 选择视频文件 / 拖放导入
PASS | m4s 自动配对 / 读取标题 / 读取封面
ALL PASSED = True
```

还有一个跑**真实转换**的端到端测试，会导入指定文件夹、转换、校验产物落盘（支持大文件）：

```bash
TMPDIR=/tmp "./dist/BiliLyu 视频转换器.app/Contents/MacOS/BiliLyu" \
  --e2e "/path/to/下载的视频文件夹" --out "/path/to/输出目录"
```

加 `--delete-originals` 可以顺便验证「转换后删除原文件」（**会真的删**，务必先用副本试）。

其它调试开关：

```bash
".../Contents/MacOS/BiliLyu" --shot out.png      # 给界面截图
".../Contents/MacOS/BiliLyu" --clear-data        # 清空网页缓存
```

---

## 实现说明（给以后的自己）

- 页面通过自定义协议 `bililive://local/` 从 `Contents/Resources/web` 加载，而不是 `file://`——为了拿到一个稳定的、`isSecureContext = true` 的来源，`blob:` Worker 和 WebAssembly 都需要它。
- **WKWebView 里 `<input type="file">` 必须由宿主实现 `WKUIDelegate` 的 `webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)`**，否则按钮点了完全没反应（这就是最初「无法导入视频」的原因）。面板按 `WKOpenPanelParameters.allowsDirectories` 决定选文件夹还是选文件。
- 网页只拿得到 `File` 对象，拿不到路径。所以 App 在打开面板、以及在 `WKWebView.performDragOperation` 里把真实 URL 记进 `SourceIndex`（文件名 → 绝对路径），转换和删除都按文件名查回真实路径。查不到时（比如拖拽没被捕获）会自动退回 wasm 路径，小文件依然能转。
- 转换时页面自己的 `convertOne` / `ensureEngine` 被 shim 替换掉了，页面保留全部 UI、队列和进度逻辑，只是把实际工作交给原生。进度用 `-progress pipe:1` 解析 `out_time_us`，再回灌给页面的 `state.running.progress`。
- 命名管道**不能**在 `defer` 里清理：`Process.run()` 是异步的，函数一返回就删目录会把管道从 ffmpeg 脚下抽走（表现为 `v.pipe: No such file or directory`）。改成在 termination handler 里清理。
- 取消和内部停止是两个标志：终止时要主动叫醒卡在 `open()` 上的写入线程，但不能因此把结果误报成「已取消」。
- `navigator.language` 在没有本地化的宿主 App 里会报 `en-US`，所以启动脚本注入系统真实语言。
- 自检里不要指望合成鼠标事件：`NSWindow.sendEvent` 发的点击**送不到** WebKit 的网页进程（`window.__overlayClicks` 始终为 0）。导入自检改为直接对 input 调 `.click()`，再用原生面板自动应答喂文件进去。

## 授权

内置的 ffmpeg 是 [eugeneware/ffmpeg-static](https://github.com/eugeneware/ffmpeg-static) 的静态构建（GPL，含 x264/x265）。自己本机使用没问题；如果要分发这个 App，需要一并遵守 GPL。
