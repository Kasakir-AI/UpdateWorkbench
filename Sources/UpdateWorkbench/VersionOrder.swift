import Foundation

/// Orders app, build and macOS version strings.
///
/// Numeric components compare as numbers and missing ones count as zero, so `2.0` and `2.0.0` are the same
/// version. A pre-release (`1.0-beta.1`, `3.1b2`, `4.0rc1`, `5.0 Preview`) comes before its release; other
/// suffixes such as `1.0 (45)` come after it. A leading `v` and semver build metadata (`+sha.1`) are ignored.
enum VersionOrder {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let left = Parsed(lhs), let right = Parsed(rhs) else {
            // Not a dotted number (for example "Unknown"): keep the plain text ordering.
            return lhs.compare(rhs, options: [.numeric, .caseInsensitive])
        }
        for index in 0..<max(left.release.count, right.release.count) {
            let a = index < left.release.count ? left.release[index] : 0
            let b = index < right.release.count ? right.release[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        if left.kind != right.kind { return left.kind < right.kind ? .orderedAscending : .orderedDescending }
        return compareSuffix(left.suffix, right.suffix)
    }

    static func isSame(_ lhs: String, _ rhs: String) -> Bool { compare(lhs, rhs) == .orderedSame }

    private enum Token: Equatable {
        case number(Int)
        case word(String)
    }

    private struct Parsed {
        enum Kind: Int, Comparable {
            case prerelease, release, suffixed
            static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        }
        var release: [Int]
        var kind: Kind
        var suffix: [Token]

        init?(_ raw: String) {
            var text = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            if text.first == "v" { text = text.dropFirst() }
            if let plus = text.firstIndex(of: "+") { text = text[..<plus] }
            var release: [Int] = []
            var digits = ""
            var rest = text.startIndex
            for index in text.indices {
                let character = text[index]
                if character.isASCII, character.isNumber {
                    digits.append(character)
                } else if character == ".", !digits.isEmpty, text.index(after: index) < text.endIndex,
                          text[text.index(after: index)].isASCII, text[text.index(after: index)].isNumber {
                    guard let value = Int(digits) else { return nil }
                    release.append(value); digits = ""
                    continue
                } else { break }
                rest = text.index(after: index)
            }
            guard let last = Int(digits) else { return nil }
            release.append(last)
            let remainder = text[rest...]
            self.release = release
            suffix = Self.tokens(remainder)
            if suffix.isEmpty { kind = .release }
            // Semver: anything after a hyphen is a pre-release, as UpdateRules.isPrerelease also treats it.
            else if remainder.first == "-" { kind = .prerelease }
            else if case .word(let word)? = suffix.first, VersionOrder.prereleaseRank[word] != nil { kind = .prerelease }
            else { kind = .suffixed }
        }

        static func tokens(_ text: Substring) -> [Token] {
            var tokens: [Token] = [], current = "", isNumber = false
            func flush() {
                guard !current.isEmpty else { return }
                tokens.append(isNumber ? Int(current).map(Token.number) ?? .word(current) : .word(current))
                current = ""
            }
            for character in text {
                if character.isASCII, character.isNumber {
                    if !isNumber { flush() }
                    isNumber = true; current.append(character)
                } else if character.isLetter {
                    if isNumber { flush() }
                    isNumber = false; current.append(character)
                } else { flush() }
            }
            flush()
            return tokens
        }
    }

    /// Pre-release words in ascending order; the same vocabulary as UpdateRules.isPrerelease.
    private static let prereleaseRank: [String: Int] = [
        "dev": 0, "nightly": 0, "snapshot": 0, "canary": 0, "unstable": 0, "test": 0,
        "alpha": 1, "a": 1, "ea": 1, "insider": 1, "insiders": 1,
        "beta": 2, "b": 2,
        "pre": 3, "preview": 3,
        "rc": 4,
    ]

    /// Semver precedence for the suffix: numbers numerically, words by pre-release rank then alphabetically,
    /// numbers before words, and a shorter list first when it is a prefix of the other.
    private static func compareSuffix(_ lhs: [Token], _ rhs: [Token]) -> ComparisonResult {
        for (a, b) in zip(lhs, rhs) where a != b {
            switch (a, b) {
            case let (.number(x), .number(y)): return x < y ? .orderedAscending : .orderedDescending
            case (.number, .word): return .orderedAscending
            case (.word, .number): return .orderedDescending
            case let (.word(x), .word(y)):
                let rankX = prereleaseRank[x] ?? 3, rankY = prereleaseRank[y] ?? 3
                if rankX != rankY { return rankX < rankY ? .orderedAscending : .orderedDescending }
                return x < y ? .orderedAscending : .orderedDescending
            }
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }
}
