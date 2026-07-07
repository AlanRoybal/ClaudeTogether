import Foundation

/// Exclusion rules parsed from a `.cottyignore` file at the FS-sync root,
/// using gitignore syntax (#72). Layered on top of
/// `FSSyncWatcher.defaultExcludedDirectoryNames` during the host-side scan.
///
/// Supported gitignore semantics:
/// - blank lines and `#` comments (escape with `\#`)
/// - `!` negation with last-match-wins ordering (escape with `\!`)
/// - trailing `/` restricts a pattern to directories
/// - a `/` at the start or middle anchors the pattern to the sync root;
///   otherwise it matches at any depth
/// - `*` (non-`/`), `?` (single non-`/`), `[...]` classes, and `**` spans
/// - trailing spaces are trimmed unless backslash-escaped
///
/// As in git, contents of an excluded directory cannot be re-included by a
/// negation; the watcher skips descendants of excluded directories entirely.
struct CottyIgnore {
    private struct Rule {
        var regex: NSRegularExpression
        var negated: Bool
        var directoryOnly: Bool
    }

    private var rules: [Rule] = []

    var isEmpty: Bool { rules.isEmpty }

    init(source: String) {
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            guard let rule = Self.parseRule(line) else { continue }
            rules.append(rule)
        }
    }

    /// Whether `relativePath` (root-relative, `/`-separated, no leading `/`)
    /// is excluded from sync. Last matching rule wins.
    func isExcluded(relativePath: String, isDirectory: Bool) -> Bool {
        var excluded = false
        let range = NSRange(relativePath.startIndex..., in: relativePath)
        for rule in rules {
            if rule.directoryOnly && !isDirectory { continue }
            if rule.negated == excluded,
               rule.regex.firstMatch(in: relativePath, range: range) != nil
            {
                excluded = !rule.negated
            }
        }
        return excluded
    }

    private static func parseRule(_ line: String) -> Rule? {
        if line.isEmpty { return nil }
        if line.hasPrefix("#") { return nil }

        var pattern = trimUnescapedTrailingSpaces(line)
        if pattern.isEmpty { return nil }

        var negated = false
        if pattern.hasPrefix("!") {
            negated = true
            pattern.removeFirst()
        } else if pattern.hasPrefix("\\#") || pattern.hasPrefix("\\!") {
            pattern.removeFirst()
        }

        var directoryOnly = false
        if pattern.hasSuffix("/") {
            directoryOnly = true
            pattern.removeLast()
        }
        if pattern.isEmpty { return nil }

        // A slash at the start or middle anchors the pattern to the root.
        let anchored = pattern.contains("/")
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        if pattern.isEmpty { return nil }

        var regexBody = translateGlob(pattern)
        if !anchored { regexBody = "(?:[^/]+/)*" + regexBody }
        guard let regex = try? NSRegularExpression(pattern: "^" + regexBody + "$") else {
            NSLog("[ct] .cottyignore: skipping unparsable pattern %@", line)
            return nil
        }
        return Rule(regex: regex, negated: negated, directoryOnly: directoryOnly)
    }

    private static func trimUnescapedTrailingSpaces(_ line: String) -> String {
        var result = line
        while result.hasSuffix(" ") {
            let trailingBackslashes = result.dropLast().reversed().prefix { $0 == "\\" }.count
            if trailingBackslashes % 2 == 1 { break }
            result.removeLast()
        }
        return result
    }

    /// Translate a gitignore glob (leading `/` already stripped) into a
    /// regular-expression body matched against the full relative path.
    private static func translateGlob(_ glob: String) -> String {
        var out = ""
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                let isDouble = i + 1 < chars.count && chars[i + 1] == "*"
                if isDouble {
                    let atStart = i == 0
                    let precededBySlash = i > 0 && chars[i - 1] == "/"
                    let followedBySlash = i + 2 < chars.count && chars[i + 2] == "/"
                    let atEnd = i + 2 == chars.count
                    if (atStart || precededBySlash) && followedBySlash {
                        // `**/` — zero or more leading path segments. The
                        // separator after it is consumed here so `a/**/b`
                        // also matches `a/b`.
                        out += "(?:[^/]+/)*"
                        i += 3
                        continue
                    }
                    if precededBySlash && atEnd {
                        // trailing `/**` — everything inside; the `/` was
                        // already emitted literally.
                        out += ".*"
                        i += 2
                        continue
                    }
                    // Other `**` behaves like a regular `*` (git semantics).
                    out += "[^/]*"
                    i += 2
                    continue
                }
                out += "[^/]*"
                i += 1
            case "?":
                out += "[^/]"
                i += 1
            case "[":
                if let (classBody, next) = characterClass(chars, from: i) {
                    out += classBody
                    i = next
                } else {
                    out += NSRegularExpression.escapedPattern(for: "[")
                    i += 1
                }
            case "\\":
                if i + 1 < chars.count {
                    out += NSRegularExpression.escapedPattern(for: String(chars[i + 1]))
                    i += 2
                } else {
                    out += NSRegularExpression.escapedPattern(for: "\\")
                    i += 1
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
                i += 1
            }
        }
        return out
    }

    /// Parse a `[...]` class starting at `start`; returns the regex fragment
    /// and the index past the closing `]`, or nil if unterminated.
    private static func characterClass(_ chars: [Character], from start: Int) -> (String, Int)? {
        var i = start + 1
        var body = ""
        if i < chars.count, chars[i] == "!" || chars[i] == "^" {
            body += "^"
            i += 1
        }
        // A `]` immediately after the opening (or negation) is a literal.
        if i < chars.count, chars[i] == "]" {
            body += "\\]"
            i += 1
        }
        while i < chars.count, chars[i] != "]" {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                body += "\\" + String(chars[i + 1])
                i += 2
                continue
            }
            if c == "-" {
                body += "-"
            } else {
                body += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        guard i < chars.count else { return nil }
        return ("[" + body + "]", i + 1)
    }
}
