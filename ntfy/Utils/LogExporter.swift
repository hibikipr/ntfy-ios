import Foundation

enum LogExporter {
    static func mergedLogFile() -> URL? {
        let merged = (lines(from: Log.appLogFileURL) + lines(from: Log.extensionLogFileURL))
            .sorted { timestamp(of: $0) < timestamp(of: $1) }

        guard !merged.isEmpty else { return nil }

        let filenameFormatter = DateFormatter()
        filenameFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "ntfy-logs-\(filenameFormatter.string(from: Date())).txt"
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)

        do {
            try merged.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            Log.e("LogExporter", "Failed to write merged log file", error)
            return nil
        }
    }

    static func clearLogs() {
        for url in [Log.appLogFileURL, Log.extensionLogFileURL] {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func lines(from fileURL: URL) -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func timestamp(of line: String) -> Date {
        guard let bracketRange = line.range(of: " [") else { return .distantPast }
        let prefix = String(line[..<bracketRange.lowerBound])
        return Log.dateFormatter.date(from: prefix) ?? .distantPast
    }
}
