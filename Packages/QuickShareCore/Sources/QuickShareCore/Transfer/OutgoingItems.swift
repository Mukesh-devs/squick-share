import Foundation
import UniformTypeIdentifiers

/// A file or text item ready to send, with its payload ID and Introduction metadata.
struct PreparedFile: Sendable {
    let url: URL
    let metadata: Nearby_Sharing_Service_Proto_FileMetadata
    var payloadID: Int64 { metadata.payloadID }
    var size: Int64 { metadata.size }
}

struct PreparedText: Sendable {
    let data: Data
    let metadata: Nearby_Sharing_Service_Proto_TextMetadata
    var payloadID: Int64 { metadata.payloadID }
}

enum OutgoingItems {
    /// Builds Introduction metadata. Zero-byte files are dropped because Google receivers
    /// reject them (PROTOCOL_NOTES §7.2, VERIFY V11).
    static func prepare(_ items: [SendItem]) throws -> (files: [PreparedFile], texts: [PreparedText], skippedEmpty: Int) {
        var files: [PreparedFile] = []
        var texts: [PreparedText] = []
        var skipped = 0
        var usedIDs = Set<Int64>()
        func newID() -> Int64 {
            var id: Int64
            repeat { id = abs(secureRandomInt64() / 2) } while id == 0 || usedIDs.contains(id)
            usedIDs.insert(id)
            return id
        }

        for item in items {
            switch item {
            case .file(let url, let parentFolder):
                let values: URLResourceValues
                do {
                    values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .nameKey])
                } catch {
                    throw TransferError.fileAccess(error.localizedDescription)
                }
                guard values.isRegularFile == true else { continue }
                let size = Int64(values.fileSize ?? 0)
                if size == 0 { skipped += 1; continue }
                var meta = Nearby_Sharing_Service_Proto_FileMetadata()
                meta.name = values.name ?? url.lastPathComponent
                meta.size = size
                meta.payloadID = newID()
                meta.id = newID()
                let type = UTType(filenameExtension: url.pathExtension)
                meta.mimeType = type?.preferredMIMEType ?? "application/octet-stream"
                meta.type = fileType(type)
                if let parentFolder, !parentFolder.isEmpty { meta.parentFolder = parentFolder }
                files.append(PreparedFile(url: url, metadata: meta))
            case .text(let string):
                let data = Data(string.utf8)
                guard !data.isEmpty, data.count <= Limits.maxBytesPayload else { continue }
                var meta = Nearby_Sharing_Service_Proto_TextMetadata()
                meta.type = textType(string)
                meta.textTitle = String(string.prefix(64))
                meta.size = Int64(data.count)
                meta.payloadID = newID()
                meta.id = newID()
                texts.append(PreparedText(data: data, metadata: meta))
            }
        }
        return (files, texts, skipped)
    }

    /// Expands folders into files, keeping each file's folder path relative to the dropped folder's parent.
    /// For a dropped folder "Photos" containing "2024/a.jpg", the file gets parentFolder "Photos/2024".
    static func expand(_ urls: [URL]) -> [SendItem] {
        var items: [SendItem] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                items.append(.file(url, parentFolder: nil))
                continue
            }
            let base = url.deletingLastPathComponent().standardizedFileURL.path
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let file = enumerator?.nextObject() as? URL {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let folderPath = file.deletingLastPathComponent().standardizedFileURL.path
                let relative = folderPath.hasPrefix(base + "/") ? String(folderPath.dropFirst(base.count + 1)) : url.lastPathComponent
                items.append(.file(file, parentFolder: relative))
            }
        }
        return items
    }

    static func fileType(_ type: UTType?) -> Nearby_Sharing_Service_Proto_FileMetadata.TypeEnum {
        guard let type else { return .unknown }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .vCard) { return .contactCard }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) { return .document }
        return .unknown
    }

    static func textType(_ string: String) -> Nearby_Sharing_Service_Proto_TextMetadata.TypeEnum {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
           url.host != nil, !trimmed.contains(" ") {
            return .url
        }
        return .text
    }
}

/// Public helpers for building send lists.
public enum SendItems {
    /// Expands dropped files and folders into send items, preserving relative folder paths.
    public static func expand(_ urls: [URL]) -> [SendItem] { OutgoingItems.expand(urls) }

    /// Number of zero-byte files among `items` (they are skipped when sending).
    public static func emptyFileCount(_ items: [SendItem]) -> Int {
        items.reduce(0) { count, item in
            guard case .file(let url, _) = item else { return count }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return count + (size == 0 ? 1 : 0)
        }
    }
}
