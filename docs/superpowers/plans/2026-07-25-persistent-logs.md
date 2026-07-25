# Persistent logs + Share Logs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Logs persist to disk (per-process files in the App Group container) instead of only going to the console, and a new "Diagnostics" section in Settings lets the user share or clear them.

**Architecture:** `Log.swift` (already shared between the `ntfy` and `ntfyNSE` targets) gains a file-writing side effect alongside its existing `print()` calls, serialized through one private `DispatchQueue` per process, with size-capped trimming. A new `LogExporter` reads both processes' files, merges them by timestamp, and writes a single temp file for the share sheet. A new `DiagnosticsView` wires this into Settings.

**Tech Stack:** Swift, Foundation (`FileManager`, `FileHandle`, `DispatchQueue`), SwiftUI, `UIActivityViewController`.

## Global Constraints

- No XCTest target exists in this project — verification is build checks (both `ntfy` and `ntfyNSE` targets, since `Log.swift` is shared) plus manual checks.
- Log files live at `<App Group container>/Logs/ntfy.log` (main app) and `<App Group container>/Logs/ntfyNSE.log` (extension) — never one shared file, to avoid needing cross-process file coordination.
- Each file is capped at 1_048_576 bytes (1MB); on exceeding that, trim down to the most recent ~750_000 bytes at a line boundary.
- Redact usernames at the four call sites that log them (`ApiService.swift` ×3, `SubscriptionManager.swift` ×1) — never by scrubbing already-formatted log text.
- The persisted file format is single-line-per-entry and deliberately different from the console's multi-line `print()` format, which stays exactly as it is today.
- `project.pbxproj` is manually maintained (no synchronized groups) — new Swift files need hand-added `PBXBuildFile`/`PBXFileReference`/group-children/Sources-build-phase entries.

---

### Task 1: `Log.swift` persists every entry to a per-process file, with size-capped trimming

**Files:**
- Modify: `ntfy/Utils/Log.swift`

**Interfaces:**
- Produces: `Log.appLogFileURL: URL`, `Log.extensionLogFileURL: URL`, `Log.dateFormatter: DateFormatter` (was `private`, now internal) — consumed by Task 3's `LogExporter`.

- [ ] **Step 1: Replace the full contents of `ntfy/Utils/Log.swift`**

Current file:

```swift
import Foundation

struct Log {
    private static let dateFormat = "yy-MM-dd hh:mm:ss.SSS"
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.locale = .current
        formatter.timeZone = .current
        return formatter
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
}

private enum LogLevel {
    case debug
    case info
    case warning
    case error
}
```

Replace with:

```swift
import Foundation

struct Log {
    private static let dateFormat = "yy-MM-dd hh:mm:ss.SSS"
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
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
        trimIfNeeded(fileURL: fileURL, handle: handle)
    }

    private static func trimIfNeeded(fileURL: URL, handle: FileHandle) {
        guard let size = try? handle.offset(), size > maxFileSize else { return }
        guard let full = try? Data(contentsOf: fileURL) else { return }
        var tail = full.suffix(Int(trimToSize))
        if let newlineIndex = tail.firstIndex(of: 0x0A) {
            tail = tail[tail.index(after: newlineIndex)...]
        }
        try? Data(tail).write(to: fileURL, options: .atomic)
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
```

Note on `other`: `d`/`i`/`w`/`e` each collect their trailing variadic into `other: [Any?]`, then pass that array as the single argument filling `log`'s own variadic `_ other: Any?...` parameter — this is pre-existing behavior in this file, unchanged by this task. `persist` receives whatever `log`'s `other` parameter actually contains at runtime and handles it with the same `compactMap`-based pattern the existing `print()` loop already uses, so persisted output stays consistent with today's console output for any given call site.

- [ ] **Step 2: Build check (both targets)**

Run: `xcodebuild build -scheme ntfy -destination 'platform=iOS Simulator,name=<available iPhone>' -quiet`
Expected: exit 0, no errors. (Building the `ntfy` scheme builds both the `ntfy` and `ntfyNSE` targets, since the extension is embedded in the app.)

- [ ] **Step 3: Manual check**

Launch the app in the Simulator, use it briefly (view a topic, trigger a poll). Then inspect the file directly on disk — e.g. `find ~/Library/Developer/CoreSimulator/Devices/<device-udid>/data/Containers/Shared/AppGroup -path '*/Logs/ntfy.log'` and `cat` it. Confirm: the file exists, contains multiple single-line entries in the new format (`<timestamp> [LEVEL] tag: message`, no `ntfyApp` literal, no emoji), and that entries keep appearing as you use the app more.

- [ ] **Step 4: Commit**

```bash
git add ntfy/Utils/Log.swift
git commit -m "Log.swift persists entries to a per-process file"
```

---

### Task 2: Redact usernames at the four call sites that log them

**Files:**
- Modify: `ntfy/Utils/ApiService.swift`
- Modify: `ntfy/Persistence/SubscriptionManager.swift`

**Interfaces:**
- Consumes: none new (existing `Log.d` calls).

- [ ] **Step 1: `ApiService.swift`**

Find (three occurrences, each on its own line — the string is identical each time except for surrounding context, replace all three):

```swift
Log.d(tag, "Polling from \(urlString) with user \(user?.username ?? "anonymous")")
```
```swift
Log.d(tag, "Polling single message from \(url) with user \(user?.username ?? "anonymous")")
```
```swift
Log.d(tag, "Checking auth for \(url) with user \(user?.username ?? "anonymous")")
```

Replace each with the same message text but `\(user != nil ? "<redacted>" : "anonymous")` in place of `\(user?.username ?? "anonymous")`:

```swift
Log.d(tag, "Polling from \(urlString) with user \(user != nil ? "<redacted>" : "anonymous")")
```
```swift
Log.d(tag, "Polling single message from \(url) with user \(user != nil ? "<redacted>" : "anonymous")")
```
```swift
Log.d(tag, "Checking auth for \(url) with user \(user != nil ? "<redacted>" : "anonymous")")
```

- [ ] **Step 2: `SubscriptionManager.swift`**

Find:

```swift
Log.d(tag, "Polling from \(subscription.urlString()) with user \(user?.username ?? "anonymous")")
```

Replace with:

```swift
Log.d(tag, "Polling from \(subscription.urlString()) with user \(user != nil ? "<redacted>" : "anonymous")")
```

- [ ] **Step 3: Build check**

Run: `xcodebuild build -scheme ntfy -destination 'platform=iOS Simulator,name=<available iPhone>' -quiet`
Expected: exit 0, no errors.

- [ ] **Step 4: Manual check**

Confirm via `grep -rn "\.username" ntfy/Utils/ApiService.swift ntfy/Persistence/SubscriptionManager.swift` that no `Log.*` call in either file references `.username` anymore (any remaining `.username` references, if any, should be non-logging code). Then, with a user configured for a subscription's server (Settings → Users), trigger a poll and confirm — via the file inspection from Task 1 Step 3 — that the corresponding log line says `with user <redacted>`, not the real username.

- [ ] **Step 5: Commit**

```bash
git add ntfy/Utils/ApiService.swift ntfy/Persistence/SubscriptionManager.swift
git commit -m "Redact usernames at the source in log messages"
```

---

### Task 3: `LogExporter` + `DiagnosticsView`, wired into Settings

**Files:**
- Create: `ntfy/Utils/LogExporter.swift`
- Create: `ntfy/Views/Settings/DiagnosticsView.swift`
- Modify: `ntfy/Views/Settings/SettingsView.swift`
- Modify: `ntfy.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `Log.appLogFileURL`, `Log.extensionLogFileURL`, `Log.dateFormatter` (Task 1).
- Produces: `LogExporter.mergedLogFile() -> URL?`, `LogExporter.clearLogs()` — consumed by `DiagnosticsView` in this same task.

- [ ] **Step 1: Create `ntfy/Utils/LogExporter.swift`**

```swift
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
```

(`timestamp(of:)` splits on the literal `" ["` that always separates the timestamp from `[LEVEL]` in the format `Log.persist` writes — see Task 1. A line with no `" ["` at all, or an unparseable prefix, sorts as `.distantPast` per the design spec, rather than being dropped.)

- [ ] **Step 2: Create `ntfy/Views/Settings/DiagnosticsView.swift`**

```swift
import SwiftUI

struct DiagnosticsView: View {
    @State private var shareFile: ShareFile?

    var body: some View {
        Group {
            Button("Share Logs") {
                shareFile = LogExporter.mergedLogFile().map(ShareFile.init)
            }
            Button("Clear Logs", role: .destructive) {
                LogExporter.clearLogs()
            }
        }
        .sheet(item: $shareFile) { file in
            ActivityView(activityItems: [file.url])
        }
    }

    private struct ShareFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    private struct ActivityView: UIViewControllerRepresentable {
        let activityItems: [Any]

        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        }

        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        }
    }
}

struct DiagnosticsView_Previews: PreviewProvider {
    static var previews: some View {
        DiagnosticsView()
    }
}
```

- [ ] **Step 3: Wire into `SettingsView.swift`**

Find:

```swift
                Section(
                    header: Text("Users"),
                    footer: Text("To access read-protected topics, you may add or edit users here. All topics for a given server will use the same user.")
                ) {
                    UserTableView(dialog: $userDialog)
                }
                Section(header: Text("About")) {
                    AboutView()
                }
```

Replace with:

```swift
                Section(
                    header: Text("Users"),
                    footer: Text("To access read-protected topics, you may add or edit users here. All topics for a given server will use the same user.")
                ) {
                    UserTableView(dialog: $userDialog)
                }
                Section(
                    header: Text("Diagnostics"),
                    footer: Text("Share or clear the app's local log files. Server URLs and topic names may appear in logs; usernames are redacted.")
                ) {
                    DiagnosticsView()
                }
                Section(header: Text("About")) {
                    AboutView()
                }
```

- [ ] **Step 4: Register both new files in `project.pbxproj` (the `ntfy` target only)**

`LogExporter.swift` belongs in the `Utils` group, alongside `Log.swift`/`LocalNotificationPoster.swift`. `DiagnosticsView.swift` belongs in the `Settings` group, alongside `AboutView.swift`/`SettingsView.swift`. Neither belongs in the `ntfyNSE` target — the extension has no Settings UI, and `LogExporter` (a main-app-only concern) reads both log files from the container without needing to run inside the extension.

1. In the `PBXBuildFile` section, right after the `LocalNotificationPoster.swift in Sources` line, add:

```
		6C21F449237133E259BCFDDA /* LogExporter.swift in Sources */ = {isa = PBXBuildFile; fileRef = 629C58C52864F45D40E2D286 /* LogExporter.swift */; };
```

Right after the `AboutView.swift in Sources` line, add:

```
		B4B2732017BB9C3BBC9FD25B /* DiagnosticsView.swift in Sources */ = {isa = PBXBuildFile; fileRef = 4EFD9D8A3A9A3D69297848DE /* DiagnosticsView.swift */; };
```

2. In the `PBXFileReference` section, right after the `LocalNotificationPoster.swift` file reference, add:

```
		629C58C52864F45D40E2D286 /* LogExporter.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LogExporter.swift; sourceTree = "<group>"; };
```

Right after the `AboutView.swift` file reference, add:

```
		4EFD9D8A3A9A3D69297848DE /* DiagnosticsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DiagnosticsView.swift; sourceTree = "<group>"; };
```

3. In the `Utils` `PBXGroup`'s `children` list, right after `B442C0DC83CB8BFE0CBC891D /* LocalNotificationPoster.swift */,`, add:

```
				629C58C52864F45D40E2D286 /* LogExporter.swift */,
```

In the `Settings` `PBXGroup`'s `children` list, right after `2939B20F2F8F293C00A52946 /* AboutView.swift */,`, add:

```
				4EFD9D8A3A9A3D69297848DE /* DiagnosticsView.swift */,
```

4. In the `ntfy` target's `PBXSourcesBuildPhase` (`9474F1B9282F2AA700CDE4DD`, **not** the `ntfyNSE` one), right after `0E323F2D6E3296F12D40E1AF /* LocalNotificationPoster.swift in Sources */,`, add:

```
				6C21F449237133E259BCFDDA /* LogExporter.swift in Sources */,
```

Right after `2939B2182F8F293C00A52946 /* AboutView.swift in Sources */,`, add:

```
				B4B2732017BB9C3BBC9FD25B /* DiagnosticsView.swift in Sources */,
```

- [ ] **Step 5: Build check**

Run: `xcodebuild build -scheme ntfy -destination 'platform=iOS Simulator,name=<available iPhone>' -quiet`
Expected: exit 0, no errors.

- [ ] **Step 6: Manual check**

Launch the app, use it briefly to generate a few log lines, then go to Settings → Diagnostics → Share Logs. Confirm: the system share sheet appears with a text file (`ntfy-logs-<timestamp>.txt`) whose content is chronologically ordered single-line entries drawn from `ntfy.log` (and `ntfyNSE.log` if it has any content — likely empty on Simulator, per the NSE-doesn't-run-on-Simulator limitation noted elsewhere in this project). Then tap Clear Logs, and tap Share Logs again — confirm the app doesn't crash and (if `mergedLogFile()` returns `nil` because both files are now empty) no share sheet appears, or if a few `Log.*` calls fired in between (e.g. from the Settings screen's own lifecycle), the shared file is very short.

- [ ] **Step 7: Commit**

```bash
git add ntfy/Utils/LogExporter.swift ntfy/Views/Settings/DiagnosticsView.swift ntfy/Views/Settings/SettingsView.swift ntfy.xcodeproj/project.pbxproj
git commit -m "Add Share Logs / Clear Logs to Settings"
```

---

## Self-Review Notes

- **Spec coverage:** per-process file persistence + trimming (Task 1), username redaction at all four identified call sites (Task 2), merge-and-share + clear (Task 3) — all five spec sections covered. The spec's "Out of scope" items (no in-app log viewer, no verbosity toggle, no additional redaction, no telemetry) are correctly not implemented anywhere in this plan.
- **Type consistency:** `Log.appLogFileURL`/`Log.extensionLogFileURL`/`Log.dateFormatter` (Task 1, all now non-`private`) are consumed with matching names and types in Task 3's `LogExporter`. `LogExporter.mergedLogFile() -> URL?` and `LogExporter.clearLogs() -> Void` (Task 3) match their declarations and their use in `DiagnosticsView` exactly.
- **No test target:** every task substitutes a build check plus a concrete manual verification for the automated test cycle this skill normally prescribes, per the project-wide constraint already established in the two prior plans this session.
