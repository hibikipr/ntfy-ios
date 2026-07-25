# Persistent logs + Share Logs

## Context

`Log.swift`'s `Log.d/i/w/e` calls only `print()` to the console. That's useless for diagnosing an issue after the fact — this session repeatedly needed `xcrun simctl launch --console-pty` just to see what the app was doing while testing notification delivery, which isn't something the user (or anyone they might ask for help) can do on a real device. This spec makes logs persist to disk and adds a "Share Logs" action to Settings so a log history can be exported (e.g. attached to a GitHub issue, or sent to whoever's helping debug something).

## Design

### 1. Where logs are written

Both the main app and the `ntfyNSE` notification-service-extension call into the same shared `Log.swift` source file, but run as separate OS processes. Rather than have both append to one shared file (which needs file coordination to stay safe under concurrent writes), each process writes to its own file in the App Group container:

- `Logs/ntfy.log` — written only by the main app
- `Logs/ntfyNSE.log` — written only by the extension

Which file a given process writes to is decided the same way `Store.swift` already distinguishes the two targets:

```swift
private static var logFileURL: URL = {
    let isExtension = Bundle.main.bundlePath.hasSuffix(".appex")
    let filename = isExtension ? "ntfyNSE.log" : "ntfy.log"
    let logsDir = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: Store.appGroup)!
        .appendingPathComponent("Logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    return logsDir.appendingPathComponent(filename)
}()
```

### 2. Persisted line format (deliberately not the console format)

The console `print()` output stays exactly as it is today — untouched by this spec. The persisted file uses a different, single-line-per-entry format: timestamp, level, tag, message, and any "other" debug objects all joined onto one line. This is a deliberate departure from the console's current multi-line style (where `other` objects print on their own indented line): a persisted log that's going to be trimmed by size and merged across two files needs unambiguous line boundaries, and a raw multi-line dump doesn't give you that without extra bookkeeping. One line in, one line out.

```
26-07-25 14:32:01.123 [DEBUG] ApiService: Polling from https://ntfy.sh/mytopic/json?poll=1&since=all with user anonymous
```

### 3. Writing and trimming

All file I/O is serialized through one private static `DispatchQueue` in `Log.swift`, so concurrent `Log.*` calls from different threads within the same process never interleave writes (this is a real gap today even for the existing `print()` calls, but `print()` tolerates it silently — a shared `FileHandle` will not). The calling thread is never blocked on disk I/O: the queue dispatch is `.async`.

After each append, if the file exceeds 1MB (1_048_576 bytes), it's trimmed down to roughly the most recent 750KB, at a line boundary (read the tail, find the first newline, drop everything before it so no partial line survives). Trimming happens on the same serial queue, so it can't race with the append that triggered it.

```swift
private static let ioQueue = DispatchQueue(label: "ntfy.log.io")
private static let maxFileSize: UInt64 = 1_048_576
private static let trimToSize: UInt64 = 750_000

private static func persist(_ line: String) {
    ioQueue.async {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
        trimIfNeeded(handle: handle)
    }
}

private static func trimIfNeeded(handle: FileHandle) {
    guard let size = try? handle.offset(), size > maxFileSize else { return }
    guard let full = try? Data(contentsOf: logFileURL) else { return }
    var tail = full.suffix(Int(trimToSize))
    if let newlineIndex = tail.firstIndex(of: 0x0A) {
        tail = tail[tail.index(after: newlineIndex)...]
    }
    try? Data(tail).write(to: logFileURL, options: .atomic)
}
```

(`handle.offset()` after a `write` already reflects the new end-of-file position, so no separate `attributesOfItem` stat call is needed.)

### 4. Redact usernames at the call site, not by scrubbing the file

Only four log lines in the codebase ever include a username, all with the identical phrasing `"... with user \(user?.username ?? "anonymous")"`:

- `ApiService.swift:17`, `ApiService.swift:30`, `ApiService.swift:87`
- `SubscriptionManager.swift:55`

No log line ever includes a password. Rather than adding generic pattern-scrubbing logic to `Log.swift` (fragile — a regex over arbitrary free-text log messages can't guarantee it catches every phrasing, now or as new call sites get added later), each of these four call sites changes to redact at the source:

```swift
// Before:
Log.d(tag, "Polling from \(urlString) with user \(user?.username ?? "anonymous")")
// After:
Log.d(tag, "Polling from \(urlString) with user \(user != nil ? "<redacted>" : "anonymous")")
```

This applies identically to the console and the persisted file (same call, same string), and is trivially auditable — `grep -rn "\.username" ntfy/Utils/Log.swift` (and everywhere `Log.*` is called) shows there's nothing left to redact.

### 5. Share Logs

New `ntfy/Views/Settings/DiagnosticsView.swift`, wired into a new "Diagnostics" section in `SettingsView.swift` (after "Users", before "About"):

- **Share Logs**: reads both `Logs/ntfy.log` and `Logs/ntfyNSE.log` (missing files are treated as empty, not an error — the extension may never have run, e.g. on Simulator), splits each into lines, parses each line's leading timestamp with the same `DateFormatter` `Log.swift` already has (exposed as an `internal` static let instead of `private`), merges and sorts the combined lines by that timestamp, writes the result to a new temp file (`NSTemporaryDirectory()/ntfy-logs-<yyyyMMdd-HHmmss>.txt`), and presents it via `UIActivityViewController`. A line whose leading timestamp fails to parse (e.g. a truncated first line left over from a trim) is still included in the output, sorted as if its timestamp were `Date.distantPast` — dropping malformed lines would silently lose log content, and their exact position among otherwise-correctly-sorted lines doesn't matter for a diagnostic file.
- **Clear Logs**: truncates both `Logs/ntfy.log` and `Logs/ntfyNSE.log` to empty in place (not deleted — an existing empty file avoids re-triggering the `fileExists`/`createFile` branch on the next write, which is harmless either way, but keeping the file simplifies the "did clearing work" manual check).

`NotificationRowView.swift` already has this exact `UIActivityViewController`-wrapping pattern for its own share sheet (private `ActivityView: UIViewControllerRepresentable`, presented via `.sheet(item:)` over an `Identifiable` wrapper struct). It's `private` to that file, so `DiagnosticsView.swift` defines its own small equivalent rather than sharing one — the type is ~8 lines and not worth extracting into a shared component for a single second caller:

```swift
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
```

## Out of scope

- No in-app log *viewer* (a scrolling list of log lines inside the app) — only export via the share sheet. Reading the shared file in Mail/Files/Messages/whatever the user shares it to is sufficient.
- No configurable log level or verbosity toggle — persists everything `Log.*` already logs today, at whatever level each call site already chose.
- No redaction beyond usernames — topic names and server URLs are left as-is, per the earlier design decision (these are generally necessary to actually debug a delivery issue, and the user explicitly scoped redaction to usernames/passwords only).
- No automatic upload/telemetry — sharing is always a manual, explicit user action via the share sheet.

## Testing

No XCTest target exists in this project — verification is build checks plus manual checks:

- Build check after each change (both `ntfy` and `ntfyNSE` targets, since `Log.swift` is shared between them).
- Manual: use the app for a while (subscribe, poll, receive a notification), then tap Share Logs — confirm the share sheet appears with a text file containing multiple recent log entries in the new single-line format, chronologically ordered.
- Manual: confirm no username ever appears in the shared file's `ApiService`/`SubscriptionManager` lines — only `<redacted>` or `anonymous`.
- Manual: tap Clear Logs, then Share Logs again — confirm the shared file is empty (or near-empty, since a few `Log.*` calls fire during the Settings screen's own lifecycle).
- Manual (best-effort, matching earlier sessions' NSE-on-Simulator limitation): trigger a push notification if functional in the test environment, confirm `ntfyNSE.log` gets an entry and it appears in the merged share output.
