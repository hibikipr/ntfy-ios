import Foundation

struct Log {
    private static let dateFormat = "yy-MM-dd HH:mm:ss.SSS"
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.locale = .current
        formatter.timeZone = .current
        return formatter
    }()

    private static let ioQueue = DispatchQueue(label: "ntfy.log.io")
    private static let maxFileSize: UInt64 = 1_048_576
    private static let trimToSize: UInt64 = 750_000
    /// Reused across appends instead of opening/closing a fresh `FileHandle` per log line.
    /// Only ever touched from `ioQueue`. Invalidated whenever the underlying file is replaced
    /// (trimming, or `LogExporter.clearLogs()`), since the old file descriptor would otherwise
    /// keep writing to the now-unlinked inode.
    private static var cachedHandle: FileHandle?

    static let appLogFileURL: URL = logsDirectory().appendingPathComponent("ntfy.log")
    static let extensionLogFileURL: URL = logsDirectory().appendingPathComponent("ntfyNSE.log")

    private static let currentLogFileURL: URL = {
        Bundle.main.bundlePath.hasSuffix(".appex") ? extensionLogFileURL : appLogFileURL
    }()

    static func d(_ tag: String, _ message: String, _ other: Any?...) {
        log(.debug, tag, message, other)
    }

    static func i(_ tag: String, _ message: String, _ other: Any?...) {
        log(.info, tag, message, other)
    }

    static func w(_ tag: String, _ message: String, _ other: Any?...) {
        log(.warning, tag, message, other)
    }

    static func e(_ tag: String, _ message: String, _ other: Any?...) {
        log(.error, tag, message, other)
    }

    private static func log(_ level: LogLevel, _ tag: String, _ message: String, _ other: Any?...) {
        print("\(dateStr()) ntfyApp [\(levelStr(level))] \(tag): \(message)")
        if !other.isEmpty {
            other.forEach { o in
                if let o = o {
                    print("  ", o)
                }
            }
        }
        persist(level: level, tag: tag, message: message, other: other)
    }

    private static func persist(level: LogLevel, tag: String, message: String, other: [Any?]) {
        var line = "\(dateStr()) [\(plainLevelStr(level))] \(tag): \(message)"
        let otherParts = other.compactMap { $0 }.map { String(describing: $0) }
        if !otherParts.isEmpty {
            line += " | " + otherParts.joined(separator: " | ")
        }
        ioQueue.async {
            append(line, to: currentLogFileURL)
        }
    }

    private static func append(_ line: String, to fileURL: URL) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        guard let handle = openHandle(for: fileURL) else { return }
        handle.write(data)
        trimIfNeeded(fileURL: fileURL, handle: handle)
    }

    private static func openHandle(for fileURL: URL) -> FileHandle? {
        if let cachedHandle {
            return cachedHandle
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return nil }
        handle.seekToEndOfFile()
        cachedHandle = handle
        return handle
    }

    /// Closes and drops the cached handle so the next append reopens the file fresh. Must be called
    /// (on `ioQueue`) whenever the log file is replaced out from under the handle.
    private static func invalidateCachedHandle() {
        try? cachedHandle?.close()
        cachedHandle = nil
    }

    private static func trimIfNeeded(fileURL: URL, handle: FileHandle) {
        guard let size = try? handle.offset(), size > maxFileSize else { return }
        guard let full = try? Data(contentsOf: fileURL) else { return }
        var tail = full.suffix(Int(trimToSize))
        if let newlineIndex = tail.firstIndex(of: 0x0A) {
            tail = tail[tail.index(after: newlineIndex)...]
        }
        try? Data(tail).write(to: fileURL, options: .atomic)
        invalidateCachedHandle()
    }

    /// Must be called whenever a log file is truncated/rewritten from outside `append(_:to:)`
    /// (e.g. `LogExporter.clearLogs()`), so a stale cached handle doesn't keep writing to the
    /// now-unlinked inode.
    static func invalidateCachedHandleAfterExternalWrite() {
        ioQueue.async {
            invalidateCachedHandle()
        }
    }

    private static func logsDirectory() -> URL {
        let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Store.appGroup)!
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func dateStr() -> String {
        dateFormatter.string(from: Date())
    }

    private static func levelStr(_ level: LogLevel) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARNING ⚠️"
        case .error: return "ERROR ‼️"
        }
    }

    private static func plainLevelStr(_ level: LogLevel) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        }
    }
}

private enum LogLevel {
    case debug
    case info
    case warning
    case error
}
