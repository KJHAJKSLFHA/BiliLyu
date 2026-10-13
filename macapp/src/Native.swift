// Native conversion for BiliLyu.
//
// The web version does everything with ffmpeg.wasm, which has to hold the whole
// input (plus a copy of the output) in memory. That is fine for a few hundred
// megabytes and hopeless for the multi-gigabyte 4K downloads Bilibili hands
// out — a 6.8 GB .m4s never fits in a browser heap.
//
// So conversion runs through a real ffmpeg binary bundled in the app instead.
// Bilibili's .m4s files carry a 9-byte "000000000" prefix in front of a normal
// MP4; ffmpeg cannot parse that, so we feed it the file from the right offset
// through a FIFO. That keeps everything streaming: no temp copy, no memory
// ceiling, and it is limited only by disk speed.

import AppKit
import Foundation
import WebKit

// MARK: - Source index

/// The page only ever sees `File` objects, never paths. Remember the real URLs
/// the user handed us (open panel or drag & drop) so conversion and deletion can
/// operate on actual files.
final class SourceIndex {
    static let shared = SourceIndex()

    private var map: [String: URL] = [:]
    private let lock = NSLock()

    func remember(_ urls: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let keys: [URLResourceKey] = [.isRegularFileKey]
                guard let walker = FileManager.default.enumerator(at: url,
                                                                  includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles,
                                                                            .skipsPackageDescendants]) else { continue }
                for case let file as URL in walker {
                    let values = try? file.resourceValues(forKeys: Set(keys))
                    guard values?.isRegularFile == true else { continue }
                    map[file.lastPathComponent] = file
                }
            } else {
                map[url.lastPathComponent] = url
            }
        }
        stderrLine("[src] index holds \(map.count) file(s)")
    }

    func url(for name: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return map[name]
    }

    func forget(name: String) {
        lock.lock()
        defer { lock.unlock() }
        map.removeValue(forKey: name)
    }
}

// MARK: - Shared conversion state

private final class ConvertState {
    private let lock = NSLock()
    private var stop = false            // releases writers blocked on open()
    private var userCancelled = false   // the user pressed 取消
    private var error: String?

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stop
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return userCancelled
    }

    var firstError: String? {
        lock.lock(); defer { lock.unlock() }
        return error
    }

    func requestStop() {
        lock.lock(); stop = true; lock.unlock()
    }

    func cancel() {
        lock.lock(); userCancelled = true; stop = true; lock.unlock()
    }

    func record(_ message: String) {
        lock.lock()
        if error == nil { error = message }
        lock.unlock()
    }
}

// MARK: - Native converter

final class NativeConverter {
    static let shared = NativeConverter()

    struct Request {
        let video: URL
        let audio: URL?
        let output: URL
        let duration: Double
    }

    enum ConvertError: LocalizedError {
        case ffmpegMissing
        case badSource(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .ffmpegMissing:    return "应用内置的 ffmpeg 不可用"
            case .badSource(let m): return m
            case .failed(let m):    return m
            }
        }
    }

    private let lock = NSLock()
    private var running: Process?
    private var currentState: ConvertState?
    private(set) var isBusy = false

    static var ffmpegURL: URL? {
        Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "bin")
    }

    var isAvailable: Bool {
        guard let url = Self.ffmpegURL else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    func cancel() {
        lock.lock()
        let proc = running
        let state = currentState
        lock.unlock()
        state?.cancel()
        if let proc = proc, proc.isRunning { proc.terminate() }
    }

    // MARK: MP4 prefix handling

    /// Bilibili prepends 9 bytes ("000000000") to the MP4. Find the real `ftyp`
    /// box and skip back over its 4-byte size field, exactly like the web app.
    static func mp4Offset(of url: URL) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64), head.count >= 8 else { return 0 }
        let bytes = [UInt8](head)
        let limit = min(64, bytes.count - 4)
        guard limit > 0 else { return 0 }
        for i in 0..<limit where bytes[i] == 0x66 && bytes[i + 1] == 0x74
                            && bytes[i + 2] == 0x79 && bytes[i + 3] == 0x70 {
            let start = i - 4
            return start > 0 ? UInt64(start) : 0
        }
        return 0
    }

    // MARK: Streaming a file into a FIFO

    private static func pump(source: URL, offset: UInt64, into fifo: String, state: ConvertState) {
        // Opening a FIFO for writing blocks until a reader shows up. Poll
        // non-blocking so we can give up if ffmpeg dies before opening it.
        var descriptor: Int32 = -1
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if state.isStopped { return }
            descriptor = open(fifo, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 { break }
            if errno != ENXIO { break }
            usleep(50_000)
        }
        guard descriptor >= 0 else {
            state.record("无法连接到 ffmpeg 输入管道")
            return
        }
        defer { close(descriptor) }

        // Back to blocking writes.
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)

        guard let handle = try? FileHandle(forReadingFrom: source) else {
            state.record("无法读取源文件：\(source.lastPathComponent)")
            return
        }
        defer { try? handle.close() }
        if offset > 0 { try? handle.seek(toOffset: offset) }

        let chunkSize = 4 * 1024 * 1024
        while !state.isStopped {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            var failed = false
            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < raw.count {
                    let n = write(descriptor, base.advanced(by: sent), raw.count - sent)
                    if n <= 0 { failed = true; return }
                    sent += n
                }
            }
            if failed {
                state.record("写入 ffmpeg 管道失败（磁盘或进程异常）")
                return
            }
        }
    }

    // MARK: Conversion

    func convert(_ request: Request,
                 progress: @escaping (Double) -> Void,
                 completion: @escaping (Result<URL, Error>) -> Void) {
        guard let ffmpeg = Self.ffmpegURL else {
            completion(.failure(ConvertError.ffmpegMissing))
            return
        }
        guard FileManager.default.fileExists(atPath: request.video.path) else {
            completion(.failure(ConvertError.badSource("找不到视频源文件：\(request.video.lastPathComponent)")))
            return
        }
        if let audio = request.audio, !FileManager.default.fileExists(atPath: audio.path) {
            completion(.failure(ConvertError.badSource("找不到音频源文件：\(audio.lastPathComponent)")))
            return
        }

        let state = ConvertState()
        lock.lock()
        currentState = state
        isBusy = true
        lock.unlock()

        try? FileManager.default.createDirectory(at: request.output.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: request.output)

        // Named pipes live here. They must survive until ffmpeg is done — the
        // process starts asynchronously, so cleaning up on return would pull the
        // pipes out from under it.
        let tempBase = ProcessInfo.processInfo.environment["BILILYU_TMPDIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let scratch = tempBase.appendingPathComponent("bililyu-\(UUID().uuidString)", isDirectory: true)
        func discardScratch() { try? FileManager.default.removeItem(at: scratch) }

        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            finish(completion, with: .failure(ConvertError.failed("无法创建临时目录：\(error.localizedDescription)")))
            return
        }

        let videoPipe = scratch.appendingPathComponent("v.pipe").path
        let audioPipe = scratch.appendingPathComponent("a.pipe").path
        guard mkfifo(videoPipe, 0o600) == 0 else {
            discardScratch()
            finish(completion, with: .failure(ConvertError.failed("无法创建输入管道：\(String(cString: strerror(errno)))")))
            return
        }
        if request.audio != nil, mkfifo(audioPipe, 0o600) != 0 {
            discardScratch()
            finish(completion, with: .failure(ConvertError.failed("无法创建输入管道：\(String(cString: strerror(errno)))")))
            return
        }

        let writers = DispatchGroup()
        let videoOffset = Self.mp4Offset(of: request.video)
        writers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.pump(source: request.video, offset: videoOffset, into: videoPipe, state: state)
            writers.leave()
        }
        if let audio = request.audio {
            let audioOffset = Self.mp4Offset(of: audio)
            writers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                Self.pump(source: audio, offset: audioOffset, into: audioPipe, state: state)
                writers.leave()
            }
        }

        var args = ["-hide_banner", "-nostdin", "-y", "-i", videoPipe]
        if request.audio != nil { args += ["-i", audioPipe] }
        args += ["-map", "0:v:0"]
        args += request.audio != nil ? ["-map", "1:a:0"] : ["-map", "0:a?"]
        args += ["-c", "copy", "-movflags", "+faststart",
                 "-nostats", "-progress", "pipe:1",
                 request.output.path]

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        var logLines: [String] = []
        let logLock = NSLock()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            logLock.lock()
            logLines.append(contentsOf: text.split(separator: "\n").map(String.init))
            if logLines.count > 60 { logLines.removeFirst(logLines.count - 60) }
            logLock.unlock()
        }

        let durationMicros = request.duration > 0 ? request.duration * 1_000_000 : 0
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                guard durationMicros > 0,
                      let micros = Double(line.dropFirst("out_time_us=".count)),
                      micros >= 0 else { continue }
                progress(min(1.0, micros / durationMicros))
            }
        }

        process.terminationHandler = { [weak self] proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            state.requestStop()          // release any writer still waiting on open()
            _ = writers.wait(timeout: .now() + 20)

            logLock.lock()
            let tail = logLines.suffix(8).joined(separator: " / ")
            logLock.unlock()
            discardScratch()

            self?.lock.lock()
            self?.running = nil
            self?.currentState = nil
            self?.isBusy = false
            self?.lock.unlock()

            let outputExists = FileManager.default.fileExists(atPath: request.output.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: request.output.path)[.size] as? Int) ?? nil

            stderrLine("[convert] ffmpeg exit=\(proc.terminationStatus) cancelled=\(state.isCancelled) size=\(size ?? -1)")

            if proc.terminationStatus == 0, let bytes = size, bytes > 0 {
                progress(1.0)
                stderrLine("[convert] ok \(request.output.path) (\(bytes) bytes)")
                completion(.success(request.output))
                return
            }

            try? FileManager.default.removeItem(at: request.output)
            let reason: String
            if let recorded = state.firstError {
                reason = recorded
            } else if state.isCancelled {
                reason = "已取消"
            } else if outputExists, let bytes = size, bytes == 0 {
                reason = "输出为空"
            } else if !tail.isEmpty {
                reason = "ffmpeg 失败：\(tail)"
            } else {
                reason = "ffmpeg 退出码 \(proc.terminationStatus)"
            }
            stderrLine("[convert] failed: \(reason)")
            completion(.failure(ConvertError.failed(reason)))
        }

        do {
            try process.run()
        } catch {
            state.requestStop()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            discardScratch()
            finish(completion, with: .failure(ConvertError.failed("无法启动 ffmpeg：\(error.localizedDescription)")))
            return
        }

        lock.lock()
        running = process
        lock.unlock()

        stderrLine("[convert] \(request.video.lastPathComponent) + \(request.audio?.lastPathComponent ?? "无音轨") → \(request.output.lastPathComponent)")
    }

    private func finish(_ completion: @escaping (Result<URL, Error>) -> Void, with result: Result<URL, Error>) {
        lock.lock()
        running = nil
        currentState = nil
        isBusy = false
        lock.unlock()
        completion(result)
    }

    // MARK: Deleting originals

    @discardableResult
    static func deleteSource(named name: String) -> Bool {
        guard let url = SourceIndex.shared.url(for: name) else {
            stderrLine("[del] no known path for \(name)")
            return false
        }
        do {
            try FileManager.default.removeItem(at: url)
            SourceIndex.shared.forget(name: name)
            stderrLine("[del] removed \(url.path)")
            return true
        } catch {
            stderrLine("[del] failed \(url.path): \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Web view that records dropped files

/// WKWebView hands Finder drops straight to the web process, so the app never
/// sees the paths. Capture them on the way through: the page-side import keeps
/// working, and we learn where the files actually live.
final class DroppableWebView: WKWebView {
    var onDropURLs: (([URL]) -> Void)?

    /// Pull file URLs out of a drag pasteboard.
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender.draggingPasteboard)
        if !urls.isEmpty { onDropURLs?(urls) }
        return super.performDragOperation(sender)
    }
}
