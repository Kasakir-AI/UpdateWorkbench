import Foundation

/// Release notes from Sparkle descriptions, Electron `releaseNotes` and GitHub release bodies.
///
/// Notes are never shown in a web view. HTML is converted to plain Markdown-style text (scripts,
/// styles, frames and embedded objects are dropped with their contents, every other tag is removed),
/// and only HTTPS links survive. The result is rendered with SwiftUI `Text`, which runs no code
/// and loads no remote content.
enum ReleaseNotes {
    static let maximumCharacters = 20_000
    static let maximumDownloadBytes = 1_048_576

    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case paragraph(text: String)
        case rule
    }

    /// Converts HTML or Markdown into safe Markdown-style plain text.
    static func sanitize(_ raw: String) -> String {
        var text = String(raw.prefix(maximumCharacters * 4))
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if looksLikeHTML(text) { text = htmlToText(text) } else { text = dropActiveContent(text) }
        // Markdown images would point at remote content: keep only their alt text.
        text = replace(#"!\[([^\]]*)\]\([^)]*\)"#, in: text, with: "$1")
        // Inline HTML inside Markdown (GitHub bodies) is removed too.
        text = stripTags(text)
        text = decodeEntities(text)
        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\t", with: "    ").trimmingTrailingWhitespace() }
        text = lines.joined(separator: "\n")
        text = replace(#"\n{3,}"#, in: text, with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maximumCharacters { text = String(text.prefix(maximumCharacters)) + "\n\n…" }
        return text
    }

    /// HTML documents (Sparkle descriptions) are converted; Markdown with a little inline HTML (GitHub bodies)
    /// keeps its line structure and only loses the tags.
    static func looksLikeHTML(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBlocks = trimmed.range(of: #"<\s*(p|br|div|ul|ol|li|h[1-6]|body|html|table|pre)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard hasBlocks || trimmed.hasPrefix("<") else { return false }
        if trimmed.hasPrefix("<") { return true }
        let markdownLines = trimmed.range(of: #"(^|\n)\s*(#{1,6}\s|[-*+]\s|\d{1,3}[.)]\s)"#, options: .regularExpression) != nil
        return !markdownLines
    }

    static func htmlToText(_ html: String) -> String {
        var text = html
        text = dropActiveContent(text)
        text = replace(#"\s*\n\s*"#, in: text, with: " ")
        text = replace(#"<br\s*/?>"#, in: text, with: "\n")
        text = replace(#"<h([1-6])\b[^>]*>"#, in: text, with: "\n\n<<H$1>>")
        text = replace(#"</h[1-6]\s*>"#, in: text, with: "\n\n")
        for level in 1...6 { text = text.replacingOccurrences(of: "<<H\(level)>>", with: String(repeating: "#", count: level) + " ") }
        text = replace(#"<li\b[^>]*>"#, in: text, with: "\n- ")
        text = replace(#"</(p|div|ul|ol|li|tr|table|blockquote|pre|section|article)\s*>"#, in: text, with: "\n")
        text = replace(#"<(p|div|ul|ol|tr|table|blockquote|pre|section|article)\b[^>]*>"#, in: text, with: "\n\n")
        text = replace(#"<hr\b[^>]*>"#, in: text, with: "\n\n---\n\n")
        text = replace(#"</?(b|strong)\b[^>]*>"#, in: text, with: "**")
        text = replace(#"</?(i|em)\b[^>]*>"#, in: text, with: "*")
        text = replace(#"</?code\b[^>]*>"#, in: text, with: "`")
        // Links: keep HTTPS targets as Markdown links, otherwise only the text.
        let anchor = try! NSRegularExpression(pattern: #"<a\b[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a\s*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        var output = ""
        var last = text.startIndex
        for match in anchor.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let hrefRange = Range(match.range(at: 1), in: text),
                  let labelRange = Range(match.range(at: 2), in: text) else { continue }
            output += text[last..<whole.lowerBound]
            let label = stripTags(String(text[labelRange])).trimmingCharacters(in: .whitespaces)
            let href = decodeEntities(String(text[hrefRange]))
            if let url = safeLink(href), !label.isEmpty { output += "[\(label.replacingOccurrences(of: "]", with: ")"))](\(url.absoluteString))" }
            else { output += label }
            last = whole.upperBound
        }
        output += text[last...]
        return stripTags(output)
    }

    /// Comments and active or embedded content are dropped together with their contents.
    static func dropActiveContent(_ input: String) -> String {
        var text = replace(#"<!--.*?-->"#, in: input, with: "")
        for tag in ["script", "style", "iframe", "object", "embed", "noscript", "template", "svg", "math", "head", "title", "form", "select", "textarea"] {
            text = replace("<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", in: text, with: "")
            text = replace("<\(tag)\\b[^>]*>.*", in: text, with: "") // unclosed: drop to the end
        }
        return text
    }

    static func stripTags(_ text: String) -> String {
        replace(#"</?[A-Za-z!][^<>]*>"#, in: text, with: "")
    }

    static func safeLink(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–",
                                       "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
                                       "bull": "•", "copy": "©", "reg": "®", "trade": "™", "rarr": "→", "larr": "←"]
        let regex = try! NSRegularExpression(pattern: #"&(#x[0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z]{2,8});"#)
        var output = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let body = Range(match.range(at: 1), in: text) else { continue }
            output += text[last..<whole.lowerBound]
            let entity = String(text[body])
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") { replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
            else if entity.hasPrefix("#") { replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
            else { replacement = named[entity.lowercased()] }
            // Control characters other than newline and tab are never produced.
            if let value = replacement, value.unicodeScalars.allSatisfy({ $0.value >= 32 || $0 == "\n" || $0 == "\t" }) { output += value }
            else { output += text[whole] }
            last = whole.upperBound
        }
        output += text[last...]
        return output
    }

    /// Splits sanitized text into display blocks.
    static func blocks(_ sanitized: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(text: paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in sanitized.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil { flush(); blocks.append(.rule); continue }
            if let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = line[match].filter { $0 == "#" }.count
                blocks.append(.heading(level: level, text: String(line[match.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "# "))))
                continue
            }
            if let match = line.range(of: #"^([-*+•]|\d{1,3}[.)])\s+"#, options: .regularExpression) {
                flush(); blocks.append(.bullet(text: String(line[match.upperBound...]))); continue
            }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    /// Inline Markdown (bold, italics, code, links) with every non-HTTPS link removed.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in attributed.runs {
            if let link = run.link, safeLink(link.absoluteString) == nil { attributed[run.range].link = nil }
            if run.imageURL != nil { attributed[run.range].imageURL = nil }
        }
        return attributed
    }

    /// Downloads a Sparkle `releaseNotesLink` (HTTPS only, at most 1 MB) and sanitizes it.
    static func fetch(_ url: URL) async throws -> String {
        let (data, response) = try await HTTPFetcher.fetch(url, maximumBytes: maximumDownloadBytes)
        guard response.statusCode == 200 else { throw HTTPFetcher.Failure(message: "The release notes returned HTTP \(response.statusCode).") }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return sanitize(text)
    }

    static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var value = self
        while let last = value.last, last == " " { value.removeLast() }
        return value
    }
}
