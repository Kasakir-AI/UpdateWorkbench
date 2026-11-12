import AppKit
import Foundation

/// The disk image carries a software license agreement that the user must accept before it can be mounted.
struct LicenseAgreementRequired: LocalizedError, Identifiable, Sendable, Equatable {
    var id = UUID()
    let appName: String
    let version: String
    let text: String
    var errorDescription: String? { "The \(appName) \(version) disk image has a license agreement. Review and accept it to continue." }
}

/// Read-only handling of DMG update payloads.
enum DiskImage {
    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    struct Resources: Equatable, Sendable {
        var hasLicense: Bool
        var licenseText: String?
    }

    /// Reads the UDIF trailer ("koly") and its resource plist without mounting anything.
    /// A license agreement is present when the resources contain `LPic`; its text comes from `TEXT` or `RTF `.
    static func resources(of dmg: URL) throws -> Resources {
        let handle = try FileHandle(forReadingFrom: dmg)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 512 else { throw Failure(message: "The download is not a valid disk image.") }
        try handle.seek(toOffset: size - 512)
        guard let trailer = try handle.read(upToCount: 512), trailer.count == 512, trailer.prefix(4) == Data("koly".utf8) else {
            throw Failure(message: "The download is not a UDIF disk image.")
        }
        func bigEndian(_ offset: Int) -> UInt64 { trailer[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) } }
        let xmlOffset = bigEndian(0xD8), xmlLength = bigEndian(0xE0)
        guard xmlLength > 0 else { return Resources(hasLicense: false, licenseText: nil) }
        guard xmlLength <= 32 * 1_048_576, xmlOffset.addingReportingOverflow(xmlLength).partialValue <= size else {
            throw Failure(message: "The disk image's resource table is invalid.")
        }
        try handle.seek(toOffset: xmlOffset)
        guard let xml = try handle.read(upToCount: Int(xmlLength)),
              let plist = try PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else {
            throw Failure(message: "The disk image's resource table could not be read.")
        }
        return parseResources(plist)
    }

    static func parseResources(_ plist: [String: Any]) -> Resources {
        guard let fork = plist["resource-fork"] as? [String: Any] else { return Resources(hasLicense: false, licenseText: nil) }
        let hasLicense = fork["LPic"] != nil
        func firstData(_ key: String) -> Data? { ((fork[key] as? [[String: Any]])?.first?["Data"]) as? Data }
        var text: String?
        if let rtf = firstData("RTF "), let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            text = attributed.string
        } else if let raw = firstData("TEXT") {
            text = String(data: raw, encoding: .macOSRoman) ?? String(decoding: raw, as: UTF8.self)
        }
        text = text?.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Resources(hasLicense: hasLicense, licenseText: text.map { String($0.prefix(200_000)) })
    }

    /// Mounts read-only, hidden from Finder and without auto-opening. A license is answered "Y" only after
    /// the user accepted it; otherwise LicenseAgreementRequired is thrown before anything is mounted.
    static func attach(_ dmg: URL, at mountPoint: URL, acceptLicense: Bool, appName: String, version: String) throws {
        let encrypted = try SyncCommand.status("/usr/bin/hdiutil", ["isencrypted", dmg.path])
        if encrypted.status == 0, encrypted.output.contains("encrypted: YES") {
            throw Failure(message: "The disk image is encrypted. Update Workbench only installs unencrypted vendor disk images.")
        }
        let info = try resources(of: dmg)
        if info.hasLicense && !acceptLicense {
            throw LicenseAgreementRequired(appName: appName, version: version, text: info.licenseText ?? "The disk image includes a license agreement, but its text could not be read. Open the vendor's website to review it before accepting.")
        }
        let arguments = ["attach", dmg.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path]
        let result = try SyncCommand.status("/usr/bin/hdiutil", arguments, input: info.hasLicense ? "Y\n" : nil)
        guard result.status == 0, isMounted(mountPoint) else {
            detach(mountPoint)
            let detail = result.output.contains("canceled") ? "The disk image asked for a license agreement that wasn't accepted." : String(result.output.suffix(600))
            throw Failure(message: "The disk image could not be mounted. \(detail)")
        }
    }

    /// Detaches, retrying and finally forcing. Safe to call when nothing is mounted.
    static func detach(_ mountPoint: URL) {
        for attempt in 0..<4 {
            guard isMounted(mountPoint) else { return }
            var arguments = ["detach", mountPoint.path, "-quiet"]
            if attempt >= 2 { arguments.append("-force") }
            _ = try? SyncCommand.status("/usr/bin/hdiutil", arguments)
            if !isMounted(mountPoint) { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    static func isMounted(_ mountPoint: URL) -> Bool {
        var info = statfs()
        guard statfs(mountPoint.path, &info) == 0 else { return false }
        let mounted = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        // realpath keeps the /private prefix that resolvingSymlinksInPath strips from /var and /tmp.
        let real = realpath(mountPoint.path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) }
        return mounted == mountPoint.path || mounted == real || mounted == mountPoint.resolvingSymlinksInPath().path
    }
}
