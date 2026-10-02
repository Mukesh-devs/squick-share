import Foundation

/// Turns peer-supplied names into safe local names (brief §5: never write outside the chosen folder).
public enum FileNameSanitizer {
    public static let maxComponentBytes = 255

    /// Sanitizes one path component (a file or folder name).
    ///
    /// Removes control and bidirectional-override characters, replaces path separators,
    /// stops leading dots (no hidden files, no `.` or `..`), and limits the UTF-8 length to 255 bytes
    /// while keeping a short extension.
    public static func sanitizeComponent(_ raw: String, fallback: String = "file") -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F:
                continue                                    // control characters
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF:
                continue                                    // bidi overrides, BOM (name spoofing)
            case 0x2F, 0x5C, 0x3A:
                scalars.append("_")                         // "/", "\", ":"
            default:
                scalars.append(scalar)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingDots = name.prefix(while: { $0 == "." }).count            // ".." becomes "__"
        name = String(repeating: "_", count: leadingDots) + name.dropFirst(leadingDots)
        if name.isEmpty { name = fallback }
        return truncate(name)
    }

    /// Sanitizes a peer-supplied relative folder path into safe components.
    /// `.` and `..` components are dropped; both `/` and `\` separate components.
    public static func sanitizeFolder(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        let parts = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true)
        var components: [String] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "." || trimmed == ".." { continue }
            components.append(sanitizeComponent(String(part), fallback: "folder"))
            if components.count == Limits.maxFolderDepth { break }
        }
        return components
    }

    /// A display-safe version of a peer-supplied label (device names, text titles).
    public static func displayString(_ raw: String, maxLength: Int = 100) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF:
                continue
            default:
                scalars.append(scalar)
            }
        }
        let text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(maxLength))
    }

    static func truncate(_ name: String) -> String {
        guard name.utf8.count > maxComponentBytes else { return name }
        let ext = (name as NSString).pathExtension
        let keepExt = !ext.isEmpty && ext.utf8.count <= 20
        let suffix = keepExt ? "." + ext : ""
        let stem = keepExt ? String(name.dropLast(suffix.count)) : name
        return EndpointInfo.truncateUTF8(stem, maxBytes: maxComponentBytes - suffix.utf8.count) + suffix
    }

    /// "name.ext" → "name (n).ext"
    static func numbered(_ name: String, _ n: Int) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let candidate = ext.isEmpty || stem.isEmpty ? "\(name) (\(n))" : "\(stem) (\(n)).\(ext)"
        return truncate(candidate)
    }
}

enum DestinationError: Error, Equatable {
    case outsideDestination
    case symlinkInPath
    case cannotCreateFolder
}

/// Resolves and creates the folder for a received file, refusing anything that escapes `root`.
enum Destination {
    static func folder(root: URL, components: [String], created: inout [URL]) throws -> URL {
        let fm = FileManager.default
        let rootResolved = root.standardizedFileURL.resolvingSymlinksInPath()
        var current = rootResolved
        for component in components {
            precondition(!component.contains("/") && component != "." && component != "..")
            current = current.appendingPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            if let attributes = try? fm.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw DestinationError.symlinkInPath
            }
            if fm.fileExists(atPath: current.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue {
                    // A file with the folder's name exists: pick a numbered folder instead.
                    var n = 1
                    let base = current.lastPathComponent
                    repeat {
                        current = current.deletingLastPathComponent().appendingPathComponent(FileNameSanitizer.numbered(base, n), isDirectory: true)
                        n += 1
                    } while fm.fileExists(atPath: current.path) && n < 10_000
                    try create(current, created: &created)
                }
            } else {
                try create(current, created: &created)
            }
        }
        let resolved = current.resolvingSymlinksInPath().path
        guard resolved == rootResolved.path || resolved.hasPrefix(rootResolved.path + "/") else {
            throw DestinationError.outsideDestination
        }
        return current
    }

    private static func create(_ url: URL, created: inout [URL]) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            created.append(url)
        } catch {
            throw DestinationError.cannotCreateFolder
        }
    }

    /// Atomically moves `temp` to `folder/name`, adding " (n)" until the name is free. Never overwrites.
    static func moveExclusive(_ temp: URL, to folder: URL, name: String) throws -> URL {
        var candidate = name
        for n in 0..<10_000 {
            if n > 0 { candidate = FileNameSanitizer.numbered(name, n) }
            let target = folder.appendingPathComponent(candidate, isDirectory: false)
            let result = temp.path.withCString { src in
                target.path.withCString { dst in renamex_np(src, dst, UInt32(RENAME_EXCL)) }
            }
            if result == 0 { return target }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw POSIXError(.EEXIST)
    }
}
