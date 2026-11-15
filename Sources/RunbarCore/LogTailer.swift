import Darwin
import Foundation

/// Follows a log file and delivers new (cleaned) lines on the main queue.
public final class LogTailer {
    public let url: URL
    private var offset: UInt64
    private var pending = Data()
    private var source: DispatchSourceFileSystemObject?
    private let onLines: ([String]) -> Void

    public init(url: URL, startOffset: UInt64, onLines: @escaping ([String]) -> Void) {
        self.url = url
        self.offset = startOffset
        self.onLines = onLines
    }

    deinit { source?.cancel() }

    public static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    public static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public func start() {
        watch()
        poll()
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    private func watch() {
        source?.cancel()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let event = src.data
            self.poll()
            if event.contains(.delete) || event.contains(.rename) {
                self.offset = 0
                self.pending.removeAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.watch() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    /// Reads what was written since the last read.
    public func poll() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            offset = 0
            pending.removeAll()
        }
        guard size > offset else { return }
        let maxChunk: UInt64 = 2_000_000
        if size - offset > maxChunk { offset = size - maxChunk }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: Int(size - offset))) ?? Data()
        offset += UInt64(data.count)
        pending.append(data)

        guard let lastBreak = pending.lastIndex(where: { $0 == 0x0A || $0 == 0x0D }) else {
            if pending.count > 64_000 { flush(all: true) }
            return
        }
        let complete = pending[pending.startIndex...lastBreak]
        pending = Data(pending[pending.index(after: lastBreak)...])
        let lines = TerminalText.lines(from: String(decoding: complete, as: UTF8.self))
        if !lines.isEmpty { onLines(lines) }
    }

    private func flush(all: Bool) {
        let lines = TerminalText.lines(from: String(decoding: pending, as: UTF8.self))
        pending.removeAll()
        if !lines.isEmpty { onLines(lines) }
    }

    /// Last `count` lines of a log file (for the CLI and the backlog).
    public static func lastLines(of url: URL, count: Int, maxBytes: UInt64 = 1_000_000) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let lines = TerminalText.lines(from: String(decoding: data, as: UTF8.self))
        return Array(lines.suffix(count))
    }
}
