import Compression
import Darwin
import Foundation

/// Symlink-aware safety checks for ZIP update payloads.
///
/// App bundles, and Electron apps in particular, ship framework links such as
/// `Versions/Current -> A`. These are accepted only when every link is relative
/// and stays inside the `.app` bundle that contains it. The archive's central
/// directory is read before anything is written, so an archive can never write
/// through a link: entries below a link, absolute or escaping targets, path
/// traversal, duplicates, encrypted entries and special file types are rejected
/// up front. After extraction the tree is checked again on disk.
enum ArchiveSafety {
    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    enum Kind: Equatable, Sendable { case file, directory, symlink, special }

    struct Entry: Equatable, Sendable {
        var path: String
        var kind: Kind
        var linkTarget: String?
        var uncompressedSize: UInt64 = 0
        var encrypted = false
    }

    static let maximumEntries = 100_000
    static let maximumLinks = 10_000
    static let maximumExpandedBytes: UInt64 = 4_294_967_296

    static func unsafe(_ detail: String) -> Failure {
        Failure(message: "This update's ZIP is unsafe to extract: \(detail). Nothing was installed. Use the app's own updater or its DMG download.")
    }

    // MARK: Listing validation (pure)

    /// Validates a ZIP listing before extraction.
    static func validate(_ entries: [Entry]) throws {
        guard entries.count < maximumEntries else { throw unsafe("it contains too many entries") }
        var seen = Set<String>()
        var links = Set<String>()
        var expanded: UInt64 = 0
        var normalizedEntries: [(components: [String], entry: Entry)] = []
        for entry in entries {
            guard !entry.encrypted else { throw unsafe("“\(entry.path)” is encrypted") }
            let components = try pathComponents(entry.path)
            let key = foldedKey(components)
            guard seen.insert(key).inserted else { throw unsafe("“\(entry.path)” appears more than once") }
            let (sum, overflow) = expanded.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, sum <= maximumExpandedBytes else { throw unsafe("it expands to more than 4 GB") }
            expanded = sum
            switch entry.kind {
            case .special:
                throw unsafe("“\(entry.path)” is a device, pipe, socket or hard link")
            case .symlink:
                guard links.count < maximumLinks else { throw unsafe("it contains too many symbolic links") }
                try validateLink(components: components, target: entry.linkTarget, name: entry.path)
                links.insert(key)
            case .file, .directory:
                break
            }
            normalizedEntries.append((components, entry))
        }
        // No entry may live below a link: otherwise extraction could write through it.
        guard !links.isEmpty else { return }
        for (components, entry) in normalizedEntries where components.count > 1 {
            for depth in 1..<components.count where links.contains(foldedKey(Array(components[0..<depth]))) {
                throw unsafe("“\(entry.path)” would be written through a symbolic link")
            }
        }
    }

    /// Splits an archive path, rejecting absolute paths, traversal and odd characters.
    static func pathComponents(_ path: String) throws -> [String] {
        var trimmed = path
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\\"), !trimmed.contains("\0") else {
            throw unsafe("“\(path)” is not a safe relative path")
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw unsafe("“\(path)” is not a safe relative path")
        }
        return components
    }

    private static func foldedKey(_ components: [String]) -> String {
        components.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
    }

    /// A link must sit inside a `.app` bundle and resolve, lexically, inside that same bundle.
    static func validateLink(components: [String], target: String?, name: String) throws {
        guard let target, !target.isEmpty, target.utf8.count <= 1024, !target.contains("\0") else {
            throw unsafe("the link “\(name)” has no valid target")
        }
        guard !target.hasPrefix("/"), !target.hasPrefix("~") else {
            throw unsafe("the link “\(name)” points to an absolute location (\(target))")
        }
        guard let appIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }),
              appIndex < components.count - 1 else {
            throw unsafe("the link “\(name)” is not inside an app bundle")
        }
        let rootDepth = appIndex + 1
        var stack = Array(components.dropLast())
        for part in target.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                stack.removeLast()
                guard stack.count >= rootDepth else { throw unsafe("the link “\(name)” points outside the app bundle (\(target))") }
            } else {
                stack.append(String(part))
            }
        }
    }

    // MARK: ZIP central directory

    /// Reads the ZIP central directory, including each link's target, without extracting anything.
    static func entries(inZIP url: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw unsafe("it is not a valid ZIP archive") }
        let tailLength = min(fileSize, 65_557)
        let tail = try read(handle, at: fileSize - tailLength, count: Int(tailLength))
        guard let eocd = tail.lastRange(of: Data([0x50, 0x4b, 0x05, 0x06])).map({ tail.distance(from: tail.startIndex, to: $0.lowerBound) }),
              eocd + 22 <= tail.count else {
            throw unsafe("it is not a valid ZIP archive")
        }
        guard tail.u16(eocd + 4) == 0, tail.u16(eocd + 6) == 0 else { throw unsafe("multi-part ZIP archives are not supported") }
        var total = UInt64(tail.u16(eocd + 10))
        var directorySize = UInt64(tail.u32(eocd + 12))
        var directoryOffset = UInt64(tail.u32(eocd + 16))
        if total == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            let locator = eocd - 20
            guard locator >= 0, tail.u32(locator) == 0x0706_4b50 else { throw unsafe("its ZIP64 directory is missing") }
            let zip64 = try read(handle, at: tail.u64(locator + 8), count: 56)
            guard zip64.u32(0) == 0x0606_4b50 else { throw unsafe("its ZIP64 directory is invalid") }
            total = zip64.u64(32); directorySize = zip64.u64(40); directoryOffset = zip64.u64(48)
        }
        guard total < UInt64(maximumEntries), directorySize <= 256 * 1_048_576,
              directoryOffset.addingReportingOverflow(directorySize).partialValue <= fileSize else {
            throw unsafe("its directory is invalid or too large")
        }
        let directory = try read(handle, at: directoryOffset, count: Int(directorySize))
        var result: [Entry] = []
        var cursor = 0
        for _ in 0..<total {
            guard cursor + 46 <= directory.count, directory.u32(cursor) == 0x0201_4b50 else { throw unsafe("its directory is corrupt") }
            let flags = directory.u16(cursor + 8), method = directory.u16(cursor + 10)
            var compressed = UInt64(directory.u32(cursor + 20)), uncompressed = UInt64(directory.u32(cursor + 24))
            let nameLength = Int(directory.u16(cursor + 28)), extraLength = Int(directory.u16(cursor + 30)), commentLength = Int(directory.u16(cursor + 32))
            let external = directory.u32(cursor + 38)
            var localOffset = UInt64(directory.u32(cursor + 42))
            let nameStart = cursor + 46, extraStart = nameStart + nameLength, next = extraStart + extraLength + commentLength
            guard next <= directory.count else { throw unsafe("its directory is corrupt") }
            guard let name = String(data: directory.subdata(in: nameStart..<extraStart), encoding: .utf8) else {
                throw unsafe("an entry name is not valid UTF-8")
            }
            // ZIP64 extended sizes and offset, in the order the format defines.
            var extra = extraStart
            while extra + 4 <= extraStart + extraLength {
                let id = directory.u16(extra), size = Int(directory.u16(extra + 2))
                var field = extra + 4
                if id == 0x0001 {
                    if uncompressed == 0xFFFF_FFFF, field + 8 <= extra + 4 + size { uncompressed = directory.u64(field); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= extra + 4 + size { compressed = directory.u64(field); field += 8 }
                    if localOffset == 0xFFFF_FFFF, field + 8 <= extra + 4 + size { localOffset = directory.u64(field) }
                }
                extra += 4 + size
            }
            let mode = external >> 16
            let kind: Kind
            switch mode & 0o170000 {
            case 0o120000: kind = .symlink
            case 0o040000: kind = .directory
            case 0o100000: kind = name.hasSuffix("/") ? .special : .file
            case 0: kind = name.hasSuffix("/") ? .directory : .file
            default: kind = .special
            }
            var entry = Entry(path: name, kind: kind, linkTarget: nil, uncompressedSize: uncompressed, encrypted: flags & 1 != 0)
            if kind == .symlink, !entry.encrypted {
                guard compressed <= 4096, uncompressed <= 1024, !name.hasSuffix("/") else { throw unsafe("the link “\(name)” is malformed") }
                entry.linkTarget = try linkTarget(handle, localOffset: localOffset, method: method, compressed: Int(compressed), uncompressed: Int(uncompressed), name: name)
            }
            result.append(entry)
            cursor = next
        }
        return result
    }

    private static func linkTarget(_ handle: FileHandle, localOffset: UInt64, method: UInt16, compressed: Int, uncompressed: Int, name: String) throws -> String {
        let header = try read(handle, at: localOffset, count: 30)
        guard header.u32(0) == 0x0403_4b50 else { throw unsafe("the link “\(name)” is malformed") }
        let dataOffset = localOffset + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
        let raw = try read(handle, at: dataOffset, count: compressed)
        let bytes: Data
        switch method {
        case 0:
            bytes = raw
        case 8:
            var output = [UInt8](repeating: 0, count: max(uncompressed, 1))
            let written = raw.withUnsafeBytes { source -> Int in
                guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(&output, output.count, base, raw.count, nil, COMPRESSION_ZLIB)
            }
            bytes = Data(output.prefix(written))
        default:
            throw unsafe("the link “\(name)” uses an unsupported compression method")
        }
        guard bytes.count == uncompressed, let target = String(data: bytes, encoding: .utf8) else {
            throw unsafe("the link “\(name)” is malformed")
        }
        return target
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else { throw unsafe("it is not a valid ZIP archive") }
        if count == 0 { return Data() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { throw unsafe("it is truncated") }
        return data
    }

    // MARK: Extraction and on-disk validation

    /// Validates the listing, then extracts into `destination`, which must be a new, empty directory.
    static func extractZIP(_ archive: URL, to destination: URL) throws {
        try validate(entries(inZIP: archive))
        let existing = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        guard existing.isEmpty else { throw Failure(message: "The extraction folder must be empty.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: "The ZIP could not be extracted: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Checks an app on disk: every link must be relative and resolve inside the bundle,
    /// only regular files, directories and links may exist, and (for ZIPs) no hard links.
    static func validateExtracted(app: URL, rejectHardLinks: Bool) throws {
        guard let rootReal = realPath(app.path) else { throw Failure(message: "The application contents could not be validated.") }
        guard let enumerator = FileManager.default.enumerator(atPath: app.path) else {
            throw Failure(message: "The application contents could not be validated.")
        }
        var count = 0
        while let relative = enumerator.nextObject() as? String {
            count += 1
            guard count < maximumEntries else { throw Failure(message: "The app contains too many filesystem entries.") }
            let path = app.path + "/" + relative
            var info = stat()
            guard lstat(path, &info) == 0 else { throw Failure(message: "The application contents could not be validated.") }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                break
            case S_IFREG:
                if rejectHardLinks, info.st_nlink > 1 { throw unsafe("“\(relative)” is a hard link") }
            case S_IFLNK:
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
                guard !target.isEmpty, !target.hasPrefix("/") else {
                    throw Failure(message: "The app contains a symbolic link with an absolute target (\(relative)).")
                }
                guard let resolved = realPath(path), resolved == rootReal || resolved.hasPrefix(rootReal + "/") else {
                    throw Failure(message: "The app contains a symbolic link that is broken or points outside its bundle (\(relative)).")
                }
            default:
                throw Failure(message: "The app contains an unsupported special filesystem entry.")
            }
        }
    }

    static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

private extension Data {
    func byte(_ offset: Int) -> UInt64 { UInt64(self[index(startIndex, offsetBy: offset)]) }
    func u16(_ offset: Int) -> UInt16 { UInt16(byte(offset) | byte(offset + 1) << 8) }
    func u32(_ offset: Int) -> UInt32 { UInt32(byte(offset) | byte(offset + 1) << 8 | byte(offset + 2) << 16 | byte(offset + 3) << 24) }
    func u64(_ offset: Int) -> UInt64 { UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32 }
}
