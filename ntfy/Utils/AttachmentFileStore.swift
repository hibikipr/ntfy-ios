//
//  AttachmentFileStore.swift
//  ntfy
//
//  Created by Alek Michelson on 5/11/26.
//

import Foundation
import CryptoKit
import UniformTypeIdentifiers

struct DownloadedAttachmentFile {
    let localFileUrl: URL
    let size: Int64
    let mimeType: String?
}

/// Handles local downloads with FileManager
enum AttachmentFileStore {
    private static let attachmentsDir = "attachments"

    static func download(
        notificationID: String,
        remoteUrl: URL,
        attachment: MessageAttachment,
        authorizationHeader: String?,
        maxSize: Int64? = nil,
        onProgress: ((Int16) -> Void)? = nil
    ) async throws -> DownloadedAttachmentFile {
        var request = URLRequest(url: remoteUrl)
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30

        let delegate = DownloadDelegate(maxSize: maxSize, onProgress: onProgress)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let (temporaryFileUrl, response) = try await delegate.download(using: session, request: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw AttachmentDownloadError.badResponse
        }

        let resolvedMimeType = attachment.type ?? httpResponse.mimeType
        let expectedSize = attachment.size ?? (response.expectedContentLength > 0 ? response.expectedContentLength : nil)
        if let maxSize, let expectedSize, expectedSize > maxSize {
            throw AttachmentDownloadError.tooLarge
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryFileUrl.path)
        let downloadedSize = (attributes[FileAttributeKey.size] as? NSNumber)?.int64Value ?? 0
        if let maxSize, downloadedSize > maxSize {
            throw AttachmentDownloadError.tooLarge
        }

        onProgress?(99)
        return try storeDownloadedTemporaryFile(
            notificationID: notificationID,
            remoteUrl: remoteUrl,
            attachment: attachment,
            temporaryFileUrl: temporaryFileUrl,
            mimeType: resolvedMimeType
        )
    }

    static func existingLocalFileUrl(
        notificationID: String,
        remoteUrl: URL,
        attachment: MessageAttachment,
        mimeType: String?
    ) -> URL? {
        guard let localFileUrl = try? localFileUrl(
            notificationID: notificationID,
            attachment: attachment,
            remoteUrl: remoteUrl,
            mimeType: mimeType
        ) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: localFileUrl.path) else {
            return nil
        }
        return localFileUrl
    }

    static func storeDownloadedTemporaryFile(
        notificationID: String,
        remoteUrl: URL,
        attachment: MessageAttachment,
        temporaryFileUrl: URL,
        mimeType: String?
    ) throws -> DownloadedAttachmentFile {
        let destinationUrl = try localFileUrl(
            notificationID: notificationID,
            attachment: attachment,
            remoteUrl: remoteUrl,
            mimeType: mimeType
        )
        try? FileManager.default.removeItem(at: destinationUrl)

        do {
            try FileManager.default.moveItem(at: temporaryFileUrl, to: destinationUrl)
        } catch {
            try FileManager.default.copyItem(at: temporaryFileUrl, to: destinationUrl)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: destinationUrl.path)
        let size = (attributes[FileAttributeKey.size] as? NSNumber)?.int64Value ?? 0
        return DownloadedAttachmentFile(localFileUrl: destinationUrl, size: size, mimeType: mimeType)
    }

    private static func localFileUrl(notificationID: String, attachment: MessageAttachment, remoteUrl: URL, mimeType: String?) throws -> URL {
        let baseDir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Store.appGroup)!
            .appendingPathComponent(attachmentsDir, isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let fileExtension = attachmentFileExtension(
            attachment: attachment,
            remoteUrl: remoteUrl,
            mimeType: mimeType
        )
        let displayName = attachment.displayName()
        let baseNameSource = URL(fileURLWithPath: displayName).deletingPathExtension().lastPathComponent
        let baseName = sanitizeAttachmentFilename(baseNameSource, fallback: "attachment")
        let sanitizedNotificationID = sanitizeAttachmentFilename(notificationID, fallback: UUID().uuidString)
        return baseDir
            .appendingPathComponent("\(sanitizedNotificationID)-\(baseName)")
            .appendingPathExtension(fileExtension)
    }
}

// MARK: Error
enum AttachmentDownloadError: LocalizedError {
    case missingUrl
    case badResponse
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .missingUrl:
            return String(localized: "Attachment URL is missing.")
        case .badResponse:
            return String(localized: "Attachment download failed.")
        case .tooLarge:
            return String(localized: "Attachment is larger than the auto-download limit.")
        }
    }
}

// MARK: Helpers
extension AttachmentFileStore {
    static private func attachmentFileExtension(attachment: MessageAttachment, remoteUrl: URL, mimeType: String?) -> String {
        let attachmentName = attachment.displayName()
        let nameExtension = URL(fileURLWithPath: attachmentName).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nameExtension.isEmpty {
            return nameExtension
        }

        let pathExtension = remoteUrl.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pathExtension.isEmpty {
            return pathExtension
        }

        if let mimeType,
           let type = UTType(mimeType: mimeType),
           let preferredExtension = type.preferredFilenameExtension {
            return preferredExtension
        }
        return "bin"
    }

    static private func sanitizeAttachmentFilename(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? fallback : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = baseName.components(separatedBy: invalidCharacters)
        let sanitized = components.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? fallback : sanitized
    }
}

// MARK: Message icons

/// Downloads and caches message icons (see `Message.icon`) in the app group, so that the
/// notification service extension and the app share them. Icons are keyed by URL, since many
/// messages usually share the same icon.
enum NotificationIconStore {
    private static let iconsDir = "icons"
    /// Icons are small images, so they never exceed this size even if attachments may.
    static let maxIconSize: Int64 = 500 * 1024
    /// Cached icons older than this are downloaded again (same as the Android app).
    static let maxCacheAge: TimeInterval = 24 * 60 * 60
    /// Unused cached icons are deleted after this long.
    private static let pruneAge: TimeInterval = 30 * 24 * 60 * 60
    /// Icons decorate the notification, so the extension shouldn't wait long for them.
    static let downloadTimeout: TimeInterval = 5

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = downloadTimeout
        config.timeoutIntervalForResource = downloadTimeout
        return URLSession(configuration: config)
    }()

    /// The maximum icon download size for the attachment auto-download setting, or nil if icons
    /// should not be downloaded at all.
    static func maxDownloadSize(autoDownloadMaxSize: Int64) -> Int64? {
        switch autoDownloadMaxSize {
        case Store.autoDownloadNever:
            return nil
        case Store.autoDownloadAlways:
            return maxIconSize
        default:
            return min(autoDownloadMaxSize, maxIconSize)
        }
    }

    /// Returns the cached icon for the URL, if any. With `maxAge`, older icons are ignored.
    static func cachedFileUrl(for url: URL, maxAge: TimeInterval? = nil, now: Date = Date()) -> URL? {
        guard let fileUrl = try? localFileUrl(for: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileUrl.path) else {
            return nil
        }
        if let maxAge, let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) > maxAge {
            return nil
        }
        return fileUrl
    }

    /// Returns the icon for the URL, downloading it unless a fresh copy is cached. A stale
    /// cached copy is returned if the download fails.
    static func icon(for url: URL, maxSize: Int64) async throws -> URL {
        if let fileUrl = cachedFileUrl(for: url, maxAge: maxCacheAge) {
            return fileUrl
        }
        do {
            return try await download(url, maxSize: maxSize)
        } catch {
            if let stale = cachedFileUrl(for: url) {
                return stale
            }
            throw error
        }
    }

    private static func download(_ url: URL, maxSize: Int64) async throws -> URL {
        // No Authorization header: icons are usually hosted elsewhere, and the ntfy server's
        // credentials must not leak to arbitrary hosts.
        var request = URLRequest(url: url, timeoutInterval: downloadTimeout)
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw AttachmentDownloadError.badResponse
        }
        if httpResponse.expectedContentLength > maxSize {
            throw AttachmentDownloadError.tooLarge
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxSize {
                throw AttachmentDownloadError.tooLarge
            }
        }
        guard isSupportedImage(data) else {
            throw AttachmentDownloadError.badResponse
        }
        let fileUrl = try localFileUrl(for: url)
        try data.write(to: fileUrl, options: .atomic)
        pruneUnusedIcons()
        return fileUrl
    }

    /// Whether the data is a JPEG or PNG image, the formats ntfy supports for icons.
    static func isSupportedImage(_ data: Data) -> Bool {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return data.starts(with: jpeg) || data.starts(with: png)
    }

    static func localFileUrl(for url: URL) throws -> URL {
        let baseDir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Store.appGroup)!
            .appendingPathComponent(iconsDir, isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        return baseDir.appendingPathComponent(cacheKey(for: url))
    }

    /// A file name for the URL: the hex SHA-256 of the URL.
    static func cacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func pruneUnusedIcons(now: Date = Date()) {
        guard let baseDir = try? localFileUrl(for: URL(fileURLWithPath: "/")).deletingLastPathComponent(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: baseDir,
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else {
            return
        }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > pruneAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
