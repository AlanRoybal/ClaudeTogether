import Foundation

/// Incremental word index for the open document. Tracks unique words
/// (case-sensitive, length >= `minWordLength`) backed by a count map so
/// that words drop out automatically once their last reference is
/// deleted.
///
/// Tokens are maximal runs of letters / digits / underscores. The
/// editor currently calls `setText(_:)` on every refresh because it is
/// O(N) and the docs we edit are tiny — `addText`/`removeText` exist for
/// callers that already know the affected slice.
@MainActor
final class EditorWordIndex {
    static let minWordLength = 3

    private var counts: [String: Int] = [:]

    /// Snapshot of all known words.
    var allWords: [String] { Array(counts.keys) }

    var isEmpty: Bool { counts.isEmpty }

    /// Reset the index from a full document text. O(N) where N is the
    /// scalar count of `text`.
    func setText(_ text: String) {
        counts.removeAll(keepingCapacity: true)
        for word in Self.tokenize(text) {
            counts[word, default: 0] += 1
        }
    }

    /// Add the words contained in `text` (e.g. an inserted region).
    func addText(_ text: String) {
        for word in Self.tokenize(text) {
            counts[word, default: 0] += 1
        }
    }

    /// Remove the words contained in `text` (e.g. a deleted region).
    /// Words whose count drops to 0 are removed entirely.
    func removeText(_ text: String) {
        for word in Self.tokenize(text) {
            if let v = counts[word] {
                if v <= 1 {
                    counts.removeValue(forKey: word)
                } else {
                    counts[word] = v - 1
                }
            }
        }
    }

    /// Return up to `limit` words starting with `prefix` (case-sensitive),
    /// excluding `excluding` so we never suggest the prefix word itself.
    /// Order: shortest first, then lexicographic — completing to the
    /// nearest match feels faster than completing to a long oddball.
    func prefixMatches(prefix: String,
                       limit: Int,
                       excluding: String? = nil) -> [String]
    {
        guard !prefix.isEmpty else { return [] }
        var matches: [String] = []
        matches.reserveCapacity(min(counts.count, limit * 4))
        for word in counts.keys {
            if word == excluding { continue }
            if word.hasPrefix(prefix) {
                matches.append(word)
            }
        }
        matches.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return lhs < rhs
        }
        if matches.count > limit {
            return Array(matches.prefix(limit))
        }
        return matches
    }

    /// Tokenize `text` into word strings. Public for tests / callers
    /// that want to compute the same boundary rules.
    static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isWordScalar(scalar) {
                current.append(scalar)
            } else {
                if current.count >= minWordLength {
                    out.append(String(current))
                }
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.count >= minWordLength {
            out.append(String(current))
        }
        return out
    }

    /// Word-token rule: letters (Unicode `isAlphabetic`), digits 0-9,
    /// or underscore. This deliberately excludes punctuation so a
    /// trailing "." or "," does not become part of the word.
    static func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
        if scalar == "_" { return true }
        if scalar.value >= 0x30 && scalar.value <= 0x39 { return true }
        return scalar.properties.isAlphabetic
    }

    /// Extract the word that ends *at* the caret (caret index is
    /// exclusive end). Returns nil if the scalar before the caret is
    /// not a word scalar — i.e. the caret is in whitespace / at
    /// beginning of a word boundary, in which case there is nothing to
    /// complete.
    static func wordEndingAt(scalars: [UnicodeScalar], caret: Int) -> String? {
        guard caret > 0, caret <= scalars.count else { return nil }
        let lastIdx = caret - 1
        guard isWordScalar(scalars[lastIdx]) else { return nil }
        var start = lastIdx
        while start > 0, isWordScalar(scalars[start - 1]) {
            start -= 1
        }
        return String(String.UnicodeScalarView(scalars[start..<caret]))
    }
}
