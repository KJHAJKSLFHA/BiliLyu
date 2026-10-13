// BiliLyu 视频转换器 — native macOS wrapper around the web app.
//
// A WKWebView hosts the local index.html through a custom URL scheme so the page
// gets a stable, secure-capable origin (needed for blob Workers + WebAssembly).
// Native code adds:
//   * a real "choose output folder" panel (the page's File System Access API is
//     unavailable in WKWebView) exposed to JS as window.__APP__
//   * a download delegate that writes converted .mp4 files into that folder
//   * an app menu, icon, and a --selftest harness

import AppKit
import WebKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Constants

let kAppName        = "BiliLyu 视频转换器"
let kScheme         = "bililive"
let kSchemeHost     = "local"
let kBridgeName     = "native"
let kVersion        = "1.0.0"
let kDefaultWidth   = 1320.0
let kDefaultHeight  = 860.0

// MARK: - Small helpers

func stderrLine(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func stdoutLine(_ s: String) {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

enum Mime {
    static func type(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "application/javascript; charset=utf-8"
        case "wasm":        return "application/wasm"
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "ico":         return "image/x-icon"
        case "mp4", "m4v":  return "video/mp4"
        case "txt", "log":  return "text/plain; charset=utf-8"
        case "woff2":       return "font/woff2"
        default:            return "application/octet-stream"
        }
    }
}

// MARK: - Settings

final class Settings {
    static let shared = Settings()
    private let key = "OutputFolderPath"

    /// --selftest sets this so its scratch folder never lands in the user's
    /// real preferences.
    var useTransientStorage = false
    private var transient: URL?

    var outputFolder: URL {
        get {
            if useTransientStorage, let t = transient { return t }
            if let p = UserDefaults.standard.string(forKey: key), !p.isEmpty {
                return URL(fileURLWithPath: p, isDirectory: true)
            }
            let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
            return dl
        }
        set {
            if useTransientStorage { transient = newValue; return }
            UserDefaults.standard.set(newValue.path, forKey: key)
        }
    }

    var outputFolderExists: Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: outputFolder.path, isDirectory: &isDir)
        return ok && isDir.boolValue
    }

    @discardableResult
    func ensureOutputFolder() -> URL {
        let dir = outputFolder
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}

// MARK: - Local asset scheme handler

/// Serves Contents/Resources/web over bililive://local/…
final class WebRootSchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    private var cache: [String: Data] = [:]
    private let lock = NSLock()

    init(root: URL) {
        self.root = root.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: kScheme, code: 400,
                userInfo: [NSLocalizedDescriptionKey: "bad request"]))
            return
        }

        var rel = url.path
        if rel.isEmpty || rel == "/" { rel = "/index.html" }
        let decoded = rel.removingPercentEncoding ?? rel
        let trimmed = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        let target = root.appendingPathComponent(trimmed).standardizedFileURL

        // Never escape the bundled web root.
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            respond(urlSchemeTask, url: url, status: 403, mime: "text/plain", data: Data("forbidden".utf8))
            return
        }

        guard let data = load(target) else {
            stderrLine("[web] 404 \(trimmed)")
            respond(urlSchemeTask, url: url, status: 404, mime: "text/plain", data: Data("not found".utf8))
            return
        }

        let mime = Mime.type(forExtension: target.pathExtension)
        // Vendor assets (the 24 MB ffmpeg core) are immutable; cache them hard so
        // every re-created ffmpeg instance does not re-read 24 MB from disk.
        let isVendor = trimmed.hasPrefix("vendor/")
        respond(urlSchemeTask, url: url, status: 200, mime: mime, data: data,
                cacheSeconds: isVendor ? 31536000 : 0)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Synchronous delivery: nothing to cancel.
    }

    private func load(_ url: URL) -> Data? {
        let key = url.path
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }

        if url.pathExtension.lowercased() == "wasm" || url.pathExtension.lowercased() == "js" {
            lock.lock()
            cache[key] = data
            lock.unlock()
        }
        return data
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, mime: String,
                         data: Data, cacheSeconds: Int = 0) {
        var headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
        ]
        headers["Cache-Control"] = cacheSeconds > 0
            ? "public, max-age=\(cacheSeconds), immutable"
            : "no-cache"

        guard let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(NSError(domain: kScheme, code: 500))
            return
        }
        task.didReceive(response)
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }
}

// MARK: - JS <-> native bridge

final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var app: AppController?

    init(app: AppController) {
        self.app = app
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any],
              let cmd = body["cmd"] as? String else {
            replyHandler(nil, "malformed message")
            return
        }

        switch cmd {
        case "info":
            let dir = Settings.shared.ensureOutputFolder()
            replyHandler([
                "isNative": true,
                "platform": "macOS",
                "version": kVersion,
                "outName": dir.lastPathComponent,
                "outPath": dir.path,
                "nativeConvert": NativeConverter.shared.isAvailable,
                "nativeDelete": true,
                "ffmpeg": NativeConverter.ffmpegURL?.path ?? "",
            ], nil)

        case "fileExists":
            guard let name = body["name"] as? String, !name.isEmpty else {
                replyHandler(false, nil); return
            }
            let safe = (name as NSString).lastPathComponent
            let candidate = Settings.shared.outputFolder.appendingPathComponent(safe)
            replyHandler(FileManager.default.fileExists(atPath: candidate.path), nil)

        case "pickOutputFolder":
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                panel.prompt = "选择"
                panel.message = "选择转换后视频的保存位置"
                panel.directoryURL = Settings.shared.outputFolder
                let result = panel.runModal()
                if result == .OK, let picked = panel.url {
                    Settings.shared.outputFolder = picked
                    Settings.shared.ensureOutputFolder()
                    replyHandler(["name": picked.lastPathComponent, "path": picked.path], nil)
                } else {
                    replyHandler(["cancelled": true], nil)
                }
            }

        case "convert":
            guard let videoName = body["video"] as? String, !videoName.isEmpty,
                  let outName = body["outName"] as? String, !outName.isEmpty else {
                replyHandler(["ok": false, "error": "转换参数不完整"], nil)
                return
            }
            guard let videoURL = SourceIndex.shared.url(for: videoName) else {
                replyHandler(["ok": false, "code": "nopath",
                              "error": "找不到源文件「\(videoName)」的磁盘路径，请改用「选择文件夹」重新导入"],
                             nil)
                return
            }
            var audioURL: URL?
            if let audioName = body["audio"] as? String, !audioName.isEmpty {
                audioURL = SourceIndex.shared.url(for: audioName)
                if audioURL == nil {
                    replyHandler(["ok": false, "code": "nopath",
                                  "error": "找不到音频文件「\(audioName)」的磁盘路径"], nil)
                    return
                }
            }
            let duration = (body["duration"] as? NSNumber)?.doubleValue ?? 0
            let itemId = (body["itemId"] as? String) ?? ""
            let outDir = Settings.shared.ensureOutputFolder()
            let target = outDir.appendingPathComponent((outName as NSString).lastPathComponent)

            let request = NativeConverter.Request(video: videoURL,
                                                  audio: audioURL,
                                                  output: target,
                                                  duration: duration)
            NativeConverter.shared.convert(request, progress: { ratio in
                DispatchQueue.main.async {
                    let js = "window.__nativeProgress && window.__nativeProgress('"
                        + AppController.jsEscape(itemId) + "', " + String(format: "%.4f", ratio) + ");"
                    AppController.sharedWebView?.evaluateJavaScript(js, completionHandler: nil)
                }
            }, completion: { result in
                switch result {
                case .success(let url):
                    replyHandler(["ok": true, "path": url.path], nil)
                case .failure(let error):
                    replyHandler(["ok": false, "error": error.localizedDescription], nil)
                }
            })

        case "cancelConvert":
            NativeConverter.shared.cancel()
            replyHandler(true, nil)

        case "deleteSource":
            guard let name = body["name"] as? String, !name.isEmpty else {
                replyHandler(false, nil)
                return
            }
            let ok = NativeConverter.deleteSource(named: (name as NSString).lastPathComponent)
            replyHandler(ok, nil)

        case "revealOutput":
            let dir = Settings.shared.ensureOutputFolder()
            NSWorkspace.shared.activateFileViewerSelecting([dir])
            replyHandler(true, nil)

        case "log":
            if let text = body["text"] as? String { stderrLine("[js] \(text)") }
            replyHandler(true, nil)

        default:
            replyHandler(nil, "unknown command: \(cmd)")
        }
    }
}

// MARK: - Injected JavaScript

enum Injected {
    /// The system's preferred language, sanitised, e.g. "zh-Hans-US".
    /// WKWebView reports navigator.language as "en-US" for an unlocalised host
    /// app, which would make this Chinese-first UI open in English.
    static var systemLanguage: String {
        let raw = Locale.preferredLanguages.first ?? "en-US"
        let safe = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return safe.isEmpty ? "en-US" : safe
    }

    /// Runs before any page script: report the real system language and publish
    /// the native handle.
    static var bootstrap: String {
        """
    (function () {
      try {
        var lang = '\(systemLanguage)';
        Object.defineProperty(navigator, 'language', { get: function () { return lang; }, configurable: true });
        Object.defineProperty(navigator, 'languages', { get: function () { return [lang, 'en']; }, configurable: true });
      } catch (e) {}
      var handlers = (window.webkit && window.webkit.messageHandlers) || {};
      window.__APP__ = {
        isNative: true,
        platform: 'macOS',
        version: '\(kVersion)',
        bridge: function (cmd, payload) {
          try {
            if (!handlers.native) return Promise.resolve(null);
            var msg = {};
            if (payload) { for (var k in payload) { msg[k] = payload[k]; } }
            msg.cmd = cmd;
            var p = handlers.native.postMessage(msg);
            return (p && typeof p.then === 'function') ? p : Promise.resolve(p);
          } catch (e) { return Promise.resolve(null); }
        }
      };
    })();
    """
    }

    /// Runs after the page's own script: make the page write into the folder the
    /// user picked in the native panel.
    static let shim = """
    (function () {
      var APP = window.__APP__;
      if (!APP || !APP.isNative) return;

      function downloadBlob(blob, name) {
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url;
        a.download = name;
        // Keep the anchor laid out but off-screen: WebKit is inconsistent about
        // firing downloads from elements that are display:none.
        a.style.cssText = 'position:fixed;left:-10000px;top:0;width:1px;height:1px;';
        a.textContent = name;
        document.body.appendChild(a);
        window.__lastDownload = { name: name, href: url, connected: a.isConnected };
        a.click();
        setTimeout(function () { a.remove(); URL.revokeObjectURL(url); }, 180000);
        return Promise.resolve();
      }

      function patchConversion() {
        if (APP.convertPatched) return;
        APP.convertPatched = true;

        window.__nativeProgress = function (id, ratio) {
          if (typeof state === 'undefined' || !state.items) return;
          var it = null;
          for (var i = 0; i < state.items.length; i++) {
            if (state.items[i].id === id) { it = state.items[i]; break; }
          }
          if (!it || typeof ratio !== 'number' || ratio < 0 || ratio > 1) return;
          it.progress = ratio;
          if (typeof paintCard === 'function') paintCard(it);
          if (typeof paintDrawer === 'function') paintDrawer();
        };

        // Replace the wasm pipeline with the bundled native ffmpeg: the page
        // keeps its UI, queue and bookkeeping, we just do the remux for real.
        var origConvertOne = window.convertOne;
        var origEnsureEngine = window.ensureEngine;

        window.convertOne = async function (it) {
          var vName = it.vrec ? it.vrec.name : '';
          var aName = it.arec ? it.arec.name : '';
          if (!vName) throw new Error('找不到源文件信息');
          var name = await uniqueOutName(it);
          var res = await APP.bridge('convert', {
            itemId: it.id, video: vName, audio: aName, outName: name, duration: it.duration || 0
          });
          if (res && res.ok) { it.outName = name; return; }

          // No disk path for this file (a drop we could not trace). Fall back to
          // the in-page wasm engine, which is fine for smaller files.
          if (res && res.code === 'nopath' && origConvertOne) {
            APP.wasmFallbackNeeded = true;
            try { return await origConvertOne(it); }
            finally { APP.wasmFallbackNeeded = false; }
          }
          throw new Error((res && res.error) || '原生转换失败');
        };

        window.ensureEngine = function () {
          if (APP.wasmFallbackNeeded) return origEnsureEngine();
          if (typeof setEngine === 'function') setEngine('ready', '原生 ffmpeg 已就绪');
          return Promise.resolve({ native: true });
        };
        window.recycleEngine = function () {
          if (typeof setEngine === 'function') setEngine('ready', '原生 ffmpeg 已就绪');
          return Promise.resolve();
        };

        var origCancelAll = window.cancelAll;
        window.cancelAll = async function () {
          try { await APP.bridge('cancelConvert'); } catch (e) {}
          return origCancelAll.apply(this, arguments);
        };

        // There is no 24 MB engine download any more.
        try {
          if (typeof I18N !== 'undefined' && I18N.zh) I18N.zh.ovSub = '使用内置 ffmpeg 原生转换，不重新编码';
          if (typeof I18N !== 'undefined' && I18N.en) I18N.en.ovSub = 'Using the bundled native ffmpeg — remux only, no re-encoding';
        } catch (e) {}
      }

      function patchDeletion() {
        if (APP.deletePatched) return;
        APP.deletePatched = true;
        if (typeof window.ingestRecords !== 'function') return;
        var origIngest = window.ingestRecords;
        // The page's records carry no delete handle (neither <input> nor drop
        // expose one in WKWebView), so hand it a native one.
        window.ingestRecords = async function (records) {
          if (records && records.length) {
            for (var i = 0; i < records.length; i++) {
              (function (r) {
                r.del = {
                  name: r.name,
                  handle: {
                    removeEntry: function (n) {
                      return APP.bridge('deleteSource', { name: n || r.name });
                    }
                  }
                };
              })(records[i]);
            }
          }
          return origIngest.apply(this, arguments);
        };
      }

      function install(info) {
        APP.outFolderName = (info && info.outName) || '';
        APP.outFolderPath = (info && info.outPath) || '';
        APP.caps = {
          nativeConvert: !!(info && info.nativeConvert),
          nativeDelete: !!(info && info.nativeDelete)
        };
        if (APP.caps.nativeConvert) patchConversion();
        if (APP.caps.nativeDelete) patchDeletion();
        if (typeof state === 'undefined' || !state) return;

        // A directory-handle lookalike backed by the native output folder.
        state.outDirName = APP.outFolderName;
        state.outDir = {
          name: APP.outFolderName,
          kind: 'directory',
          requestPermission: function () { return Promise.resolve('granted'); },
          queryPermission: function () { return Promise.resolve('granted'); },
          getFileHandle: function (name, opts) {
            var create = !!(opts && opts.create);
            return APP.bridge('fileExists', { name: name }).then(function (exists) {
              // Mirrors the real File System Access API: a missing entry is an
              // error unless the caller asked to create it.
              if (!exists && !create) {
                var err = new Error('A requested file or directory could not be found');
                err.name = 'NotFoundError';
                throw err;
              }
              return {
                kind: 'file',
                name: name,
                getFile: function () { return Promise.reject(new Error('unsupported')); },
                createWritable: function () {
                  return Promise.resolve({
                    write: function (blob) { return downloadBlob(blob, name); },
                    close: function () { return Promise.resolve(); },
                    abort: function () { return Promise.resolve(); }
                  });
                }
              };
            });
          },
          removeEntry: function () { return Promise.reject(new Error('unsupported')); },
          values: function () { return { next: function () { return Promise.resolve({ done: true }); } }; }
        };

        if (typeof refreshOutPath === 'function') refreshOutPath();
        var clearBtn = document.getElementById('btnOutClear');
        if (clearBtn) clearBtn.classList.add('hidden');
      }

      function wireOutputPicker() {
        var btn = document.getElementById('btnOutDir');
        if (!btn || btn.__nativeWired) return;
        btn.__nativeWired = true;
        var clone = btn.cloneNode(true);
        btn.parentNode.replaceChild(clone, btn);
        clone.addEventListener('click', function () {
          APP.bridge('pickOutputFolder').then(function (r) {
            if (!r || r.cancelled || !r.name) return;
            install({ outName: r.name, outPath: r.path });
            if (typeof toast === 'function' && typeof t === 'function') {
              toast(t('toastOutSet', { name: r.name }), 'ok');
            }
          });
        });
      }

      // Native tells us when a converted file landed on disk.
      window.__nativeOnSaved = function (name) {
        if (typeof toast === 'function') toast('已保存：' + name, 'ok');
      };

      // Called when the folder is changed from the native menu.
      window.__nativeFolderChanged = function (info) {
        install(info);
        if (typeof toast === 'function' && info && info.outName) {
          toast('输出文件夹：' + info.outName, 'ok');
        }
      };

      function boot() {
        wireOutputPicker();
        APP.bridge('info').then(function (info) { if (info) install(info); });
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
      } else {
        boot();
      }
    })();
    """
}

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    private var bridge: Bridge!
    private var activeDownloads: [ObjectIdentifier: WKDownload] = [:]
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var savedCount = 0

    /// Hooks used by the --selftest harness. It must not take over as
    /// navigation delegate, otherwise these download callbacks never fire.
    var onPageLoaded: (() -> Void)?
    var onPageFailed: ((Error) -> Void)?

    /// --selftest sets this so the file chooser answers automatically.
    var autoOpenPanelPaths: [URL]?
    /// How many times WebKit asked us to show a file chooser.
    var panelInvocationCount = 0

    /// The bridge needs a handle on the live web view for progress callbacks.
    static weak var sharedWebView: WKWebView?

    static func jsEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "'", with: "\\'")
             .replacingOccurrences(of: "\n", with: " ")
    }

    private var webRoot: URL {
        let res = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return res.appendingPathComponent("web", isDirectory: true)
    }

    // MARK: Configuration shared by app + selftest

    func makeWebView(persistent: Bool = true) -> WKWebView {
        let config = WKWebViewConfiguration()

        config.websiteDataStore = persistent ? .default() : .nonPersistent()

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Injected.bootstrap,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Injected.shim,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        bridge = Bridge(app: self)
        controller.addScriptMessageHandler(bridge, contentWorld: .page, name: kBridgeName)
        config.userContentController = controller

        config.setURLSchemeHandler(WebRootSchemeHandler(root: webRoot), forURLScheme: kScheme)
        config.preferences.isElementFullscreenEnabled = true

        let web = DroppableWebView(frame: .zero, configuration: config)
        web.onDropURLs = { urls in SourceIndex.shared.remember(urls) }
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsMagnification = true
        web.allowsBackForwardNavigationGestures = false
        if #available(macOS 12.0, *) {
            web.underPageBackgroundColor = NSColor(red: 0.055, green: 0.067, blue: 0.086, alpha: 1)
        }
        if #available(macOS 13.3, *) {
            web.isInspectable = true
        }
        return web
    }

    func indexURL() -> URL {
        URL(string: "\(kScheme)://\(kSchemeHost)/index.html")!
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.shared.ensureOutputFolder()
        buildMenu()

        let rect = NSRect(x: 0, y: 0, width: kDefaultWidth, height: kDefaultHeight)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered,
                          defer: false)
        window.title = kAppName
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.055, green: 0.067, blue: 0.086, alpha: 1)
        window.minSize = NSSize(width: 960, height: 620)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BiliLyuMainWindow")
        window.center()

        webView = makeWebView()
        webView.frame = window.contentView!.bounds
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)

        AppController.sharedWebView = webView
        webView.load(URLRequest(url: indexURL()))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 \(kAppName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 \(kAppName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(kAppName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        let pick = NSMenuItem(title: "选择输出文件夹…", action: #selector(chooseOutputFolder(_:)), keyEquivalent: "o")
        pick.target = self
        fileMenu.addItem(pick)
        let open = NSMenuItem(title: "在访达中打开输出文件夹", action: #selector(openOutputFolder(_:)), keyEquivalent: "O")
        open.keyEquivalentModifierMask = [.command, .shift]
        open.target = self
        fileMenu.addItem(open)
        fileMenu.addItem(.separator())
        let reload = NSMenuItem(title: "重新载入界面", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        reload.target = self
        fileMenu.addItem(reload)

        // Edit menu (needed for text fields)
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // View menu
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        viewItem.submenu = viewMenu
        let zin = NSMenuItem(title: "放大", action: #selector(zoomInPage(_:)), keyEquivalent: "+")
        zin.target = self
        viewMenu.addItem(zin)
        let zout = NSMenuItem(title: "缩小", action: #selector(zoomOutPage(_:)), keyEquivalent: "-")
        zout.target = self
        viewMenu.addItem(zout)
        let zreset = NSMenuItem(title: "实际大小", action: #selector(zoomResetPage(_:)), keyEquivalent: "0")
        zreset.target = self
        viewMenu.addItem(zreset)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "进入全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")

        // Window menu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc func chooseOutputFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择转换后视频的保存位置"
        panel.directoryURL = Settings.shared.outputFolder
        if panel.runModal() == .OK, let picked = panel.url {
            Settings.shared.outputFolder = picked
            Settings.shared.ensureOutputFolder()
            webView.evaluateJavaScript("window.__APP__ && window.__APP__.bridge('info').then(function(i){ if (window.__nativeFolderChanged) window.__nativeFolderChanged(i); });",
                                       completionHandler: nil)
        }
    }

    @objc func openOutputFolder(_ sender: Any?) {
        let dir = Settings.shared.ensureOutputFolder()
        NSWorkspace.shared.open(dir)
    }

    @objc func reloadPage(_ sender: Any?) {
        webView.load(URLRequest(url: indexURL()))
    }

    @objc func zoomInPage(_ sender: Any?) {
        webView.pageZoom = min(3.0, webView.pageZoom + 0.1)
    }

    @objc func zoomOutPage(_ sender: Any?) {
        webView.pageZoom = max(0.5, webView.pageZoom - 0.1)
    }

    @objc func zoomResetPage(_ sender: Any?) {
        webView.pageZoom = 1.0
    }

    // MARK: File & folder pickers

    /// WKWebView refuses to open a file chooser unless the host implements this
    /// delegate method — without it, clicking "选择视频文件 / 选择视频文件夹" does
    /// absolutely nothing.
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        panelInvocationCount += 1
        stderrLine("[open] invoked: allowsDirectories=\(parameters.allowsDirectories) multiple=\(parameters.allowsMultipleSelection)")
        if let auto = autoOpenPanelPaths {
            // --selftest answers the chooser without showing UI, but still goes
            // through the same path bookkeeping as a real selection.
            stderrLine("[open] auto-answer with \(auto.count) path(s)")
            SourceIndex.shared.remember(auto)
            completionHandler(auto)
            return
        }

        let wantsDirectory = parameters.allowsDirectories
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = wantsDirectory
        panel.canChooseFiles = !wantsDirectory
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.prompt = "选择"
        panel.message = wantsDirectory
            ? "选择包含视频（或 B 站 .m4s 文件）的文件夹"
            : "选择要转换的视频文件"

        if panel.runModal() == .OK {
            stderrLine("[open] user chose \(panel.urls.count) item(s)")
            SourceIndex.shared.remember(panel.urls)
            completionHandler(panel.urls)
        } else {
            completionHandler(nil)
        }
    }

    // MARK: Navigation / downloads

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        stderrLine("[web] loaded")
        onPageLoaded?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        stderrLine("[web] navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        stderrLine("[web] provisional navigation failed: \(error.localizedDescription)")
        onPageFailed?(error)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // An <a download> click arrives here with shouldPerformDownload set; a
        // blob URL never navigates, so WebKit hands it to the download delegate.
        if navigationAction.shouldPerformDownload {
            stderrLine("[dl] policy=download \(navigationAction.request.url?.absoluteString.prefix(64) ?? "")")
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            stderrLine("[dl] response not displayable → download")
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
        activeDownloads[ObjectIdentifier(download)] = download
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
        activeDownloads[ObjectIdentifier(download)] = download
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = Settings.shared.ensureOutputFolder()
        let safeName = suggestedFilename.isEmpty ? "output.mp4" : (suggestedFilename as NSString).lastPathComponent
        let dest = Self.uniqueDestination(in: dir, fileName: safeName)
        destinations[ObjectIdentifier(download)] = dest
        stderrLine("[save] \(dest.path)")
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        // Never drop the last reference to a WKDownload from inside its own
        // delegate callback, and keep the callback body to plain work.
        let key = ObjectIdentifier(download)
        let name = destinations[key]?.lastPathComponent ?? ""
        savedCount += 1
        stderrLine("[save] done \(name)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.destinations.removeValue(forKey: key)
            self.activeDownloads.removeValue(forKey: key)
            guard !name.isEmpty, let webView = self.webView else { return }
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("window.__nativeOnSaved && window.__nativeOnSaved('\(escaped)');",
                                       completionHandler: nil)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        stderrLine("[save] failed: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            self?.destinations.removeValue(forKey: key)
            self?.activeDownloads.removeValue(forKey: key)
        }
    }

    static func uniqueDestination(in dir: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = dir.appendingPathComponent(fileName)
        var i = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            i += 1
            let next = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(next)
        }
        return candidate
    }
}

// MARK: - Self test

final class SelfTest: NSObject, WKNavigationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var controller: AppController!
    private var finished = false
    private var probeURL: URL?
    private var fixtureURL: URL?
    private var importSteps: [[String: Any]] = []

    /// A miniature Bilibili download: videoInfo.json + cover + split m4s streams.
    private static let onePixelJPEG = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAAbADADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwCCiiivqz87CiiigAooooAKKKKACiiigAooooA//9k="

    private func makeFixture(in dir: URL) -> URL? {
        let fx = dir.appendingPathComponent("fixture", isDirectory: true)
        try? FileManager.default.removeItem(at: fx)
        guard (try? FileManager.default.createDirectory(at: fx, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let meta: [String: Any] = [
            "title": "自检视频 · 导入测试",
            "duration": 93,
            "qn": 80,
            "uname": "测试UP主",
            "bvid": "BV1xx411c7mD",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta) {
            try? data.write(to: fx.appendingPathComponent("videoInfo.json"))
        }
        if let jpeg = Data(base64Encoded: Self.onePixelJPEG) {
            try? jpeg.write(to: fx.appendingPathComponent("image.jpg"))
        }
        // Bilibili naming: <prefix>-<id>.m4s, 30xxx = video, 30280 = audio.
        try? Data(repeating: 0x11, count: 8192).write(to: fx.appendingPathComponent("114514-30080.m4s"))
        try? Data(repeating: 0x22, count: 4096).write(to: fx.appendingPathComponent("114514-30280.m4s"))
        return fx
    }

    static let testScript = """
    const R = { steps: [], logs: [] };
    function step(name, ok, extra) { R.steps.push({ name: name, ok: !!ok, extra: extra === undefined ? null : String(extra) }); }
    function tail(n) { return R.logs.slice(-n).join('\\n'); }
    function newEngine() {
      const e = FFmpeg.createFFmpeg({
        corePath: CORE_PATH,
        mainName: 'main',
        log: true,
        logger: function (m) { if (R.logs.length < 3000) R.logs.push(m); }
      });
      return e.load().then(function () { return e; });
    }
    try {
      step('page origin', location.origin, location.origin + ' | secure=' + window.isSecureContext);
      step('language detection', true,
           'navigator.language=' + navigator.language +
           ' languages=' + JSON.stringify(navigator.languages) +
           ' saved=' + (function(){ try { return String(localStorage.getItem('vc2_lang')); } catch (e) { return 'err'; } })() +
           ' lang=' + (typeof lang !== 'undefined' ? lang : 'n/a'));
      step('FFmpeg global', typeof FFmpeg !== 'undefined', typeof FFmpeg);
      step('CORE_PATH', typeof CORE_PATH === 'string', CORE_PATH);

      const jsRes = await fetch(CORE_PATH);
      step('fetch ffmpeg-core.js', jsRes.ok, jsRes.status + ' ' + jsRes.headers.get('content-type'));

      const wasmURL = CORE_PATH.replace(/\\.js$/, '.wasm');
      const wRes = await fetch(wasmURL);
      const wBuf = await wRes.arrayBuffer();
      step('fetch ffmpeg-core.wasm', wRes.ok && wBuf.byteLength > 1000000,
           wRes.status + ' ' + wRes.headers.get('content-type') + ' ' + wBuf.byteLength + ' bytes');
      R.wasmBytes = wBuf.byteLength;
      step('wasm magic', new Uint8Array(wBuf.slice(0, 4)).join(',') === '0,97,115,109',
           new Uint8Array(wBuf.slice(0, 4)).join(','));

      let workerErr = { value: '' };
      let workerOk = await (async function () {
        try {
          const src = 'self.onmessage=function(){self.postMessage("alive")};';
          const worker = new Worker(URL.createObjectURL(new Blob([src], { type: 'application/javascript' })));
          const alive = await new Promise(function (res) {
            const to = setTimeout(function () { res(false); }, 6000);
            worker.onmessage = function (e) { clearTimeout(to); res(e.data === 'alive'); };
            worker.onerror = function (e) {
              clearTimeout(to);
              workerErr.value = String((e && e.message) || e);
              res(false);
            };
            worker.postMessage('ping');
          });
          worker.terminate();
          return alive;
        } catch (e) { workerErr.value = String(e); return false; }
      })();
      step('blob Worker round trip', workerOk, workerErr.value);

      R.logs.length = 0;
      const i1 = await newEngine();
      step('engine load (createFFmpeg + load)', true, 'ok');

      i1.FS('writeFile', 'probe.bin', new Uint8Array([1, 2, 3, 4, 5]));
      const back = i1.FS('readFile', 'probe.bin');
      step('FS write/read round trip', back.length === 5 && back[0] === 1, back.length + ' bytes');

      await i1.run('-hide_banner', '-y', '-f', 'lavfi', '-i', 'testsrc=duration=1:size=192x108:rate=10',
                   '-pix_fmt', 'yuv420p', '-c:v', 'libx264', '-preset', 'ultrafast', '-t', '1', 'sample.mp4');
      const sample = i1.FS('readFile', 'sample.mp4');
      const made = sample && sample.length > 0;
      step('encode sample.mp4 (lavfi + libx264)', made,
           made ? sample.length + ' bytes' : 'empty | ' + tail(12));
      try { i1.exit(); } catch (e) {}

      if (made) {
        const i2 = await newEngine();
        i2.FS('writeFile', 'in.mp4', sample);
        await i2.run('-i', 'in.mp4', '-map', '0:v:0', '-map', '0:a?', '-c', 'copy',
                     '-movflags', '+faststart', 'out.mp4');
        const outp = i2.FS('readFile', 'out.mp4');
        const ftyp = outp && String.fromCharCode(outp[4], outp[5], outp[6], outp[7]);
        step('remux -c copy + faststart (app path)', outp && outp.length > 0,
             (outp ? outp.length + ' bytes' : 'empty') + ' ftyp=' + ftyp);
        try { i2.exit(); } catch (e) {}
      }

      const info = await window.__APP__.bridge('info');
      step('native bridge', !!(info && info.isNative), info ? info.outPath : 'no reply');
      step('output folder set', !!(info && info.outPath), info && info.outPath);

      // Exercise the exact save path used for converted videos:
      // page -> pseudo directory handle -> blob -> WKDownload -> disk.
      R.probeName = '__bililyu_selftest__.mp4';
      if (navigator.userActivation) {
        step('user activation before save', navigator.userActivation.hasBeenActive,
             'hasBeenActive=' + navigator.userActivation.hasBeenActive +
             ' isActive=' + navigator.userActivation.isActive);
      }
      try {
        const handle = await state.outDir.getFileHandle(R.probeName, { create: true });
        const writable = await handle.createWritable();
        await writable.write(new Blob([new Uint8Array([0, 0, 0, 32, 102, 116, 121, 112, 105, 115, 111, 109])],
                                      { type: 'video/mp4' }));
        await writable.close();
        step('save path triggered (page → blob → download)', true, R.probeName);
        const last = window.__lastDownload;
        step('anchor state', !!(last && last.connected),
             last ? (last.href.slice(0, 40) + '… connected=' + last.connected) : 'no anchor recorded');
      } catch (e) {
        step('save path triggered (page → blob → download)', false, String((e && e.message) || e));
      }
      await new Promise(function (r) { setTimeout(r, 1500); });
    } catch (e) {
      step('EXCEPTION', false, (e && (e.stack || e.message)) || String(e));
      R.error = String((e && (e.stack || e.message)) || e);
    }
    return JSON.stringify(R);
    """

    func run() {
        // --out <dir> lets the harness save its probe file somewhere harmless.
        let argv = CommandLine.arguments
        Settings.shared.useTransientStorage = true
        if let idx = argv.firstIndex(of: "--out"), idx + 1 < argv.count {
            Settings.shared.outputFolder = URL(fileURLWithPath: argv[idx + 1], isDirectory: true)
        }
        Settings.shared.ensureOutputFolder()
        probeURL = Settings.shared.outputFolder.appendingPathComponent("__bililyu_selftest__.mp4")
        try? FileManager.default.removeItem(at: probeURL!)
        fixtureURL = makeFixture(in: Settings.shared.outputFolder)
        if let fx = fixtureURL { stderrLine("[selftest] fixture at \(fx.path)") }

        controller = AppController()
        let rect = NSRect(x: 0, y: 0, width: 1100, height: 760)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "\(kAppName) — 自检"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.055, green: 0.067, blue: 0.086, alpha: 1)

        webView = controller.makeWebView(persistent: false)
        controller.webView = webView
        AppController.sharedWebView = webView
        controller.onPageLoaded = { [weak self] in self?.pageLoaded() }
        controller.onPageFailed = { [weak self] error in
            self?.finish(ok: false, payload: "{\"error\":\"navigation: \(Self.escape(error.localizedDescription))\"}")
        }
        webView.frame = window.contentView!.bounds
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)
        window.center()
        window.makeKeyAndOrderFront(nil)

        stderrLine("[selftest] loading \(controller.indexURL().absoluteString)")
        stderrLine("[selftest] output folder \(Settings.shared.outputFolder.path)")
        var target = controller.indexURL()
        if let idx = argv.firstIndex(of: "--url"), idx + 1 < argv.count, let override = URL(string: argv[idx + 1]) {
            target = override
            stderrLine("[selftest] URL override → \(target.absoluteString)")
        }
        webView.load(URLRequest(url: target))

        // Hard ceiling so a hung engine can never wedge the process.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self = self, !self.finished else { return }
            self.finish(ok: false, payload: "{\"error\":\"selftest timed out after 300s\"}")
        }
    }

    private func pageLoaded() {
        stderrLine("[selftest] page loaded, granting user activation, then running checks…")
        // Real use always follows a click on the page, and WebKit only allows a
        // programmatic download after user activation. Reproduce that here so the
        // save path is tested under the same conditions as the shipping app.
        grantUserActivation { [weak self] in
            guard let self = self else { return }
            webView.callAsyncJavaScript(Self.testScript,
                                        arguments: [:],
                                        in: nil,
                                        in: .page) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let value):
                    let text = (value as? String) ?? "\(value)"
                    self.awaitSavedFile(payload: text, attemptsLeft: 100)
                case .failure(let error):
                    self.finish(ok: false, payload: "{\"error\":\"\(Self.escape(error.localizedDescription))\"}")
                }
            }
        }
    }

    /// Put a transparent overlay over the page, click it through the normal AppKit
    /// event path (so WebKit sees a trusted click), then carry on.
    private func grantUserActivation(completion: @escaping () -> Void) {
        let js = """
        (function () {
          window.__overlayClicks = 0;
          var d = document.createElement('div');
          d.id = '__bililyu_gesture__';
          d.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:transparent';
          d.addEventListener('click', function () { window.__overlayClicks++; d.remove(); });
          document.body.appendChild(d);
          return true;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.simulateClick()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    // The synthetic click grants activation; make sure the
                    // overlay is gone either way so it cannot block later clicks.
                    self?.webView.evaluateJavaScript(
                        "var d = document.getElementById('__bililyu_gesture__'); if (d) d.remove();",
                        completionHandler: nil)
                    completion()
                }
            }
        }
    }

    private func simulateClick() {
        guard let window = window, let content = window.contentView else { return }
        let inWindow = content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: nil)
        let stamp = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type,
                                              location: inWindow,
                                              modifierFlags: [],
                                              timestamp: stamp,
                                              windowNumber: window.windowNumber,
                                              context: nil,
                                              eventNumber: 0,
                                              clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
        }
        stderrLine("[selftest] simulated click at \(inWindow)")
    }

    /// Wait for the download delegate to land the probe file, then record it.
    /// Polls via the run loop rather than nesting one, so delegate callbacks
    /// are never re-entered.
    private func awaitSavedFile(payload: String, attemptsLeft: Int) {
        guard let probe = probeURL else {
            finish(ok: true, payload: payload)
            return
        }
        if FileManager.default.fileExists(atPath: probe.path) || attemptsLeft <= 0 {
            afterEnginePhase(payload: appendSaveResult(to: payload, probe: probe))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.awaitSavedFile(payload: payload, attemptsLeft: attemptsLeft - 1)
        }
    }

    private func appendSaveResult(to payload: String, probe: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: probe.path))?[.size] as? Int
        let landed = size != nil
        let entry: [String: Any] = [
            "name": "file landed in output folder",
            "ok": landed,
            "extra": landed ? "\(probe.lastPathComponent) \(size ?? 0) bytes → \(probe.deletingLastPathComponent().path)"
                            : "nothing appeared at \(probe.path)",
        ]
        try? FileManager.default.removeItem(at: probe)

        var nativeSteps: [[String: Any]] = []
        let ffmpegPath = NativeConverter.ffmpegURL?.path ?? ""
        nativeSteps.append(["name": "内置 ffmpeg 可用",
                            "ok": NativeConverter.shared.isAvailable,
                            "extra": ffmpegPath.isEmpty ? "缺失" : ffmpegPath])

        // Drag & drop hands file URLs to the app through a pasteboard; check the
        // extraction half of that path.
        let board = NSPasteboard(name: NSPasteboard.Name("com.bililyu.selftest.drag"))
        board.clearContents()
        var dragged: [URL] = []
        if let probe = fixtureURL?.appendingPathComponent("videoInfo.json"),
           board.writeObjects([probe as NSURL]) {
            dragged = DroppableWebView.fileURLs(from: board)
        }
        nativeSteps.append(["name": "拖拽文件 URL 提取",
                            "ok": dragged.first?.lastPathComponent == "videoInfo.json",
                            "extra": dragged.isEmpty ? "未解析出 URL"
                                   : dragged.map { $0.lastPathComponent }.joined(separator: ", ")])

        return merging(nativeSteps + [entry], into: payload)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Import (file chooser) phase

    private func afterEnginePhase(payload: String) {
        guard fixtureURL != nil else {
            finish(ok: true, payload: payload)
            return
        }
        runImportPhase(payload: payload)
    }

    private func runImportPhase(payload: String) {
        guard let fixture = fixtureURL else {
            finish(ok: true, payload: payload)
            return
        }
        controller.autoOpenPanelPaths = [fixture]
        controller.panelInvocationCount = 0

        // Drive the real input, then (if WebKit declined the synthetic gesture)
        // fall back to a hand-built FileList so the page-side import chain still
        // gets exercised.
        let script = """
        const report = { steps: [], nativeItems: 0, fallbackUsed: false };
        const dirInput = document.getElementById('dirInput');

        function snapshot() {
          const items = (typeof state !== 'undefined' && state.items) ? state.items : [];
          return items.map(function (i) {
            return { title: i.title, kind: i.kind, audio: !!i.arec, video: !!i.vrec, cover: !!i.coverUrl };
          });
        }

        try {
          report.inputDisplay = getComputedStyle(dirInput).display;
          dirInput.click();
          report.clickDispatched = true;
        } catch (e) {
          report.clickDispatched = false;
          report.clickError = String(e);
        }
        await new Promise(function (r) { setTimeout(r, 1500); });
        report.nativeItems = snapshot().length;

        if (report.nativeItems === 0) {
          report.fallbackUsed = true;
          const meta = JSON.stringify({ title: '自检视频 · 导入测试', duration: 93, qn: 80,
                                        uname: '测试UP主', bvid: 'BV1xx411c7mD' });
          const jpeg = Uint8Array.from(atob('__JPEG__'), function (c) { return c.charCodeAt(0); });
          const dt = new DataTransfer();
          dt.items.add(new File([meta], 'videoInfo.json', { type: 'application/json' }));
          dt.items.add(new File([jpeg], 'image.jpg', { type: 'image/jpeg' }));
          dt.items.add(new File([new Uint8Array(8192)], '114514-30080.m4s'));
          dt.items.add(new File([new Uint8Array(4096)], '114514-30280.m4s'));
          dirInput.files = dt.files;
          dirInput.dispatchEvent(new Event('change', { bubbles: true }));
          await new Promise(function (r) { setTimeout(r, 1200); });
        }

        report.items = snapshot();
        report.toast = (document.getElementById('toast') || {}).textContent || '';
        report.overlayClicks = window.__overlayClicks || 0;
        report.overlayGone = !document.getElementById('__bililyu_gesture__');
        return JSON.stringify(report);
        """.replacingOccurrences(of: "__JPEG__", with: Self.onePixelJPEG)

        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            self.controller.autoOpenPanelPaths = nil

            var report: [String: Any] = [:]
            if case .success(let value) = result, let text = value as? String,
               let data = text.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                report = obj
            }

            let panelCalls = self.controller.panelInvocationCount
            let items = (report["items"] as? [[String: Any]]) ?? []
            let first = items.first
            let usedFallback = (report["fallbackUsed"] as? Bool) ?? false
            let inputDisplay = (report["inputDisplay"] as? String) ?? "?"

            var steps: [[String: Any]] = []
            steps.append(["name": "原生文件选择器回调被调用",
                          "ok": panelCalls > 0,
                          "extra": "panelInvocationCount=\(panelCalls) · dirInput display=\(inputDisplay)"])
            steps.append(["name": "选择文件夹 → 成功导入",
                          "ok": !items.isEmpty,
                          "extra": items.isEmpty
                              ? "0 个条目"
                              : "\(items.count) 个条目" + (usedFallback ? "（经 FileList 回退路径）" : "（经原生选择器）")])
            let kind = (first?["kind"] as? String) ?? "-"
            let audio = (first?["audio"] as? Bool) ?? false
            let video = (first?["video"] as? Bool) ?? false
            steps.append(["name": "m4s 音视频自动配对",
                          "ok": kind == "dash" && audio && video,
                          "extra": "kind=\(kind) video=\(video) audio=\(audio)"])
            let title = (first?["title"] as? String) ?? "-"
            steps.append(["name": "读取 videoInfo.json 标题",
                          "ok": title.contains("自检视频"),
                          "extra": title])
            let cover = (first?["cover"] as? Bool) ?? false
            steps.append(["name": "读取同目录封面 image.jpg",
                          "ok": cover,
                          "extra": "coverUrl=\(cover)"])

            self.importSteps = steps
            self.runFileInputPhase(payload: payload)
        }
    }

    /// Same delegate, but driven by the "选择视频文件" input (allowsDirectories
    /// must be false there, so the panel has to accept files).
    private func runFileInputPhase(payload: String) {
        guard let fixture = fixtureURL else {
            let allOk = importSteps.allSatisfy { ($0["ok"] as? Bool) ?? false }
            finish(ok: allOk, payload: merging(importSteps, into: payload))
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: fixture,
                                                                  includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "m4s" || $0.lastPathComponent == "videoInfo.json" } ?? []
        controller.autoOpenPanelPaths = files
        controller.panelInvocationCount = 0

        let script = """
        if (typeof state !== 'undefined') {
          state.items.forEach(function (i) {
            if (i.coverUrl && i.coverUrl.slice(0, 5) === 'blob:') {
              try { URL.revokeObjectURL(i.coverUrl); } catch (e) {}
            }
          });
          state.items = [];
          if (state.sel) state.sel.clear();
        }
        document.getElementById('fileInput').click();
        await new Promise(function (r) { setTimeout(r, 1800); });
        const items = (typeof state !== 'undefined' && state.items) ? state.items : [];
        const f = items[0] || {};
        return JSON.stringify({ count: items.length, title: f.title || '-', kind: f.kind || '-',
                                video: !!f.vrec, audio: !!f.arec });
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            self.controller.autoOpenPanelPaths = nil
            var report: [String: Any] = [:]
            if case .success(let value) = result, let text = value as? String,
               let data = text.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                report = obj
            }
            let count = (report["count"] as? NSNumber)?.intValue ?? 0
            let kind = (report["kind"] as? String) ?? "-"
            let video = (report["video"] as? Bool) ?? false
            let audio = (report["audio"] as? Bool) ?? false
            let panelCalls = self.controller.panelInvocationCount

            // For a file input WebKit must NOT ask for directories.
            self.importSteps.append(["name": "选择视频文件 → 成功导入",
                                     "ok": count > 0 && panelCalls > 0 && kind == "dash" && video && audio,
                                     "extra": "panelInvocationCount=\(panelCalls) · \(count) 个条目 · kind=\(kind) video=\(video) audio=\(audio)"])

            self.runDropPhase(payload: payload)
        }
    }

    /// The page also advertises "把视频或整个文件夹拖到这里". Finder drags are
    /// handled by WebKit itself; this checks the page-side drop handler.
    private func runDropPhase(payload: String) {
        let script = """
        if (typeof state !== 'undefined') {
          state.items.forEach(function (i) {
            if (i.coverUrl && i.coverUrl.slice(0, 5) === 'blob:') {
              try { URL.revokeObjectURL(i.coverUrl); } catch (e) {}
            }
          });
          state.items = [];
        }
        const dt = new DataTransfer();
        dt.items.add(new File([JSON.stringify({ title: '拖放测试 · 自检', duration: 12 })],
                              'videoInfo.json', { type: 'application/json' }));
        dt.items.add(new File([new Uint8Array(4096)], 'drag-30080.m4s'));
        dt.items.add(new File([new Uint8Array(2048)], 'drag-30280.m4s'));
        let ev;
        try {
          ev = new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt });
        } catch (e) {
          ev = new Event('drop', { bubbles: true, cancelable: true });
          Object.defineProperty(ev, 'dataTransfer', { value: dt });
        }
        document.dispatchEvent(ev);
        await new Promise(function (r) { setTimeout(r, 1200); });
        const items = (typeof state !== 'undefined' && state.items) ? state.items : [];
        const f = items[0] || {};
        return JSON.stringify({ count: items.length, title: f.title || '-', kind: f.kind || '-',
                                video: !!f.vrec, audio: !!f.arec });
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            var report: [String: Any] = [:]
            if case .success(let value) = result, let text = value as? String,
               let data = text.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                report = obj
            }
            let count = (report["count"] as? NSNumber)?.intValue ?? 0
            let kind = (report["kind"] as? String) ?? "-"
            let title = (report["title"] as? String) ?? "-"
            let video = (report["video"] as? Bool) ?? false
            let audio = (report["audio"] as? Bool) ?? false
            self.importSteps.append(["name": "拖放导入 → 成功",
                                     "ok": count > 0 && kind == "dash" && video && audio,
                                     "extra": "\(count) 个条目 · kind=\(kind) video=\(video) audio=\(audio) · title=\(title)"])

            let allOk = self.importSteps.allSatisfy { ($0["ok"] as? Bool) ?? false }
            self.finish(ok: allOk, payload: self.merging(self.importSteps, into: payload))
        }
    }

    /// Append extra steps to a result payload and recompute allPassed.
    private func merging(_ extra: [[String: Any]], into payload: String) -> String {
        guard var obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
            return payload
        }
        var steps = (obj["steps"] as? [[String: Any]]) ?? []
        steps.append(contentsOf: extra)
        obj["steps"] = steps
        obj["allPassed"] = steps.allSatisfy { ($0["ok"] as? Bool) ?? false }
        if let out = try? JSONSerialization.data(withJSONObject: obj),
           let str = String(data: out, encoding: .utf8) {
            return str
        }
        return payload
    }

    private func finish(ok: Bool, payload: String) {
        if finished { return }
        finished = true
        stdoutLine("<<<SELFTEST_JSON>>>")
        stdoutLine(payload)
        stdoutLine("<<<END_SELFTEST_JSON>>>")
        stderrLine("[selftest] exiting ok=\(ok)")
        // Let WebKit finish tearing down before leaving the process.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(ok ? 0 : 1) }
    }
}

// MARK: - Snapshot mode

/// Renders the UI offscreen and writes a PNG. Handy for checking the packaged
/// app without needing screen-recording permission.
final class Snapshot: NSObject {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var controller: AppController!
    private let outPath: String

    init(outPath: String) {
        self.outPath = outPath
    }

    func run() {
        controller = AppController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 900),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = kAppName
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.055, green: 0.067, blue: 0.086, alpha: 1)

        webView = controller.makeWebView()
        controller.webView = webView
        AppController.sharedWebView = webView
        controller.onPageLoaded = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { self?.capture() }
        }
        webView.frame = window.contentView!.bounds
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: controller.indexURL()))

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            stderrLine("[shot] timed out")
            exit(1)
        }
    }

    private func capture() {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        webView.takeSnapshot(with: config) { [weak self] image, error in
            guard let self = self else { return }
            guard let image = image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                stderrLine("[shot] failed: \(error?.localizedDescription ?? "no image")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(1) }
                return
            }
            try? png.write(to: URL(fileURLWithPath: self.outPath))
            stderrLine("[shot] wrote \(self.outPath) (\(png.count) bytes)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
    }
}

// MARK: - End-to-end conversion test

/// Drives a real conversion through the app: import a folder, convert it, then
/// report. Used to verify the native ffmpeg path against actual multi-gigabyte
/// Bilibili downloads.
final class E2ETest: NSObject {
    private let sourceFolder: URL
    private let outFolder: URL
    private var window: NSWindow!
    private var webView: WKWebView!
    private var controller: AppController!
    private var finished = false
    private var polls = 0

    init(sourceFolder: URL, outFolder: URL) {
        self.sourceFolder = sourceFolder
        self.outFolder = outFolder
    }

    func run() {
        Settings.shared.useTransientStorage = true
        Settings.shared.outputFolder = outFolder
        try? FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)

        controller = AppController()
        controller.autoOpenPanelPaths = [sourceFolder]

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "\(kAppName) — 端到端转换测试"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.055, green: 0.067, blue: 0.086, alpha: 1)

        webView = controller.makeWebView()
        controller.webView = webView
        AppController.sharedWebView = webView
        controller.onPageLoaded = { [weak self] in self?.importAndConvert() }
        webView.frame = window.contentView!.bounds
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: controller.indexURL()))

        stderrLine("[e2e] source=\(sourceFolder.path)")
        stderrLine("[e2e] output=\(outFolder.path)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 7200) { [weak self] in
            guard let self = self, !self.finished else { return }
            self.emit(steps: [["name": "整体超时", "ok": false, "extra": "超过 120 分钟"]])
        }
    }

    private func importAndConvert() {
        stderrLine("[e2e] page ready, importing…")
        let script = """
        window.__e2eError = '';
        window.addEventListener('unhandledrejection', function (e) {
          window.__e2eError = String((e.reason && e.reason.stack) || e.reason);
        });
        window.addEventListener('error', function (e) { window.__e2eError = String(e.message); });
        document.getElementById('dirInput').click();
        await new Promise(function (r) { setTimeout(r, 5000); });
        const items = (typeof state !== 'undefined' && state.items) ? state.items : [];
        const wantDelete = __DELETE_ORIGINALS__;
        if (items.length > 0) {
          if (wantDelete) {
            state.deleteOriginals = true;
            const sw = document.getElementById('swDel');
            if (sw) sw.classList.add('on');
          }
          items.forEach(function (i) { state.sel.add(i.id); });
          startConvert(Array.from(state.sel));
        }
        return JSON.stringify({
          imported: items.length,
          inputFiles: document.getElementById('dirInput').files.length,
          toast: (document.getElementById('toast') || {}).textContent || '',
          error: window.__e2eError || '',
          deletable: items.map(function (i) { return !!i.deletable; })
        });
        """
        let wantDelete = CommandLine.arguments.contains("--delete-originals")
        let finalScript = script.replacingOccurrences(of: "__DELETE_ORIGINALS__",
                                                      with: wantDelete ? "true" : "false")
        webView.callAsyncJavaScript(finalScript, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            var imported = 0
            if case .success(let value) = result, let text = value as? String,
               let data = text.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                imported = (obj["imported"] as? NSNumber)?.intValue ?? 0
            }
            stderrLine("[e2e] imported \(imported) item(s)")
            if case .success(let value) = result, let text = value as? String {
                stderrLine("[e2e] page report: \(text)")
            } else if case .failure(let error) = result {
                stderrLine("[e2e] script failed: \(error.localizedDescription)")
            }
            if imported == 0 {
                self.emit(steps: [["name": "导入真实文件夹", "ok": false, "extra": "0 个条目"]])
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.poll() }
        }
    }

    private func poll() {
        guard !finished else { return }
        polls += 1
        let script = """
        JSON.stringify({
          active: !!state.running || state.queue.length > 0,
          items: state.items.map(function (i) {
            return { title: i.title, status: i.status, message: i.message || '',
                     outName: i.outName || '', progress: i.progress || 0 };
          })
        });
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self = self else { return }
            var report: [String: Any] = [:]
            if let text = result as? String, let data = text.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                report = obj
            }
            let active = (report["active"] as? Bool) ?? false
            let items = (report["items"] as? [[String: Any]]) ?? []
            if self.polls % 20 == 0, let f = items.first {
                let pct = Int(((f["progress"] as? NSNumber)?.doubleValue ?? 0) * 100)
                stderrLine("[e2e] \(f["status"] ?? "?") \(pct)%")
            }
            if !active {
                self.report(items: items)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.poll() }
        }
    }

    private func report(items: [[String: Any]]) {
        var steps: [[String: Any]] = []
        let first = items.first
        let status = (first?["status"] as? String) ?? "-"
        let message = (first?["message"] as? String) ?? ""
        let outName = (first?["outName"] as? String) ?? ""
        let title = (first?["title"] as? String) ?? "-"

        steps.append(["name": "导入真实文件夹", "ok": !items.isEmpty,
                      "extra": "\(items.count) 个条目 · 标题=\(title)"])
        steps.append(["name": "转换状态", "ok": status == "done",
                      "extra": "status=\(status)\(message.isEmpty ? "" : " · " + message)"])

        let wantDelete = CommandLine.arguments.contains("--delete-originals")
        if wantDelete {
            let remaining = (try? FileManager.default.contentsOfDirectory(at: sourceFolder,
                                                                          includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "m4s" }.count ?? -1
            steps.append(["name": "转换后删除原文件", "ok": remaining == 0,
                          "extra": "源目录剩余 .m4s 文件：\(remaining)"])
        }

        var outputBytes = 0
        if !outName.isEmpty {
            let url = outFolder.appendingPathComponent(outName)
            outputBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }
        let sizeText = outputBytes >= 1_048_576
            ? String(format: "%.1f MB", Double(outputBytes) / 1_048_576)
            : String(format: "%.1f KB", Double(outputBytes) / 1024)
        steps.append(["name": "输出文件落盘", "ok": outputBytes > 0,
                      "extra": outName.isEmpty ? "没有输出文件名"
                             : "\(outName) · \(sizeText) → \(outFolder.path)"])
        emit(steps: steps)
    }

    private func emit(steps: [[String: Any]]) {
        if finished { return }
        finished = true
        let payload: [String: Any] = [
            "steps": steps,
            "allPassed": steps.allSatisfy { ($0["ok"] as? Bool) ?? false },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            stdoutLine("<<<SELFTEST_JSON>>>")
            stdoutLine(text)
            stdoutLine("<<<END_SELFTEST_JSON>>>")
        }
        let ok = (payload["allPassed"] as? Bool) ?? false
        stderrLine("[e2e] done ok=\(ok)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(ok ? 0 : 1) }
    }
}

// MARK: - Entry point

let args = CommandLine.arguments

// A dead ffmpeg leaves our FIFO writers writing into a closed pipe; we want
// EPIPE back, not a fatal signal.
signal(SIGPIPE, SIG_IGN)

let application = NSApplication.shared
application.setActivationPolicy(.regular)

if args.contains("--selftest") {
    let test = SelfTest()
    test.run()
    application.run()
} else if let idx = args.firstIndex(of: "--e2e"), idx + 1 < args.count {
    var out = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    if let oi = args.firstIndex(of: "--out"), oi + 1 < args.count {
        out = URL(fileURLWithPath: args[oi + 1], isDirectory: true)
    }
    let test = E2ETest(sourceFolder: URL(fileURLWithPath: args[idx + 1], isDirectory: true),
                       outFolder: out)
    test.run()
    application.run()
} else if args.contains("--clear-data") {
    // Wipe cached website data (localStorage, caches) for a clean first run.
    let store = WKWebsiteDataStore.default()
    store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                     modifiedSince: .distantPast) {
        stderrLine("[data] website data cleared")
        exit(0)
    }
    application.run()
} else if let idx = args.firstIndex(of: "--shot"), idx + 1 < args.count {
    let shot = Snapshot(outPath: args[idx + 1])
    shot.run()
    application.run()
} else {
    let controller = AppController()
    application.delegate = controller
    application.run()
}
