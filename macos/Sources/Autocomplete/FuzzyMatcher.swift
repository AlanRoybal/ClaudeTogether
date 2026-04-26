import Foundation

/// Subsequence-based fuzzy matcher. The needle's scalars must appear
/// in `haystack` in the same order (case-insensitive). Score is a
/// "distance" — *lower means tighter*. Scoring rewards consecutive
/// matches (small inter-match gaps) and head-anchored matches.
///
/// Used for shared-input command history fuzzy completion. Editor
/// completion uses prefix matching (separate path).
enum FuzzyMatcher {
    /// Returns nil if `needle` is not a subsequence of `haystack`.
    /// Otherwise returns a non-negative distance score where lower is
    /// better.
    ///
    /// The breakdown:
    ///   * Each gap between consecutive needle hits adds `gap * 2`.
    ///   * The offset of the first match (head distance) adds `firstMatchJ`.
    ///   * Trailing un-matched haystack adds `(h.count - lastMatchJ - 1)`.
    ///
    /// Both inputs are lowercased so completion is case-insensitive
    /// regardless of how the user typed.
    static func subsequenceScore(needle: String, haystack: String) -> Int? {
        let n = Array(needle.lowercased().unicodeScalars)
        let h = Array(haystack.lowercased().unicodeScalars)
        if n.isEmpty { return 0 }
        if n.count > h.count { return nil }

        var score = 0
        var i = 0
        var j = 0
        var lastMatchJ = -1
        var firstMatchJ = -1

        while i < n.count, j < h.count {
            if n[i] == h[j] {
                if firstMatchJ < 0 { firstMatchJ = j }
                if lastMatchJ >= 0 {
                    let gap = j - lastMatchJ - 1
                    score += gap * 2
                }
                lastMatchJ = j
                i += 1
            }
            j += 1
        }

        guard i == n.count else { return nil }
        score += max(0, h.count - lastMatchJ - 1)
        score += max(0, firstMatchJ)
        return score
    }

    /// Rank `candidates` against `needle`, dropping non-matches. Ties
    /// are broken by `recencyRank` (lower rank = more recent), then
    /// alphabetically. Returns up to `limit` results.
    static func rank(candidates: [String],
                     needle: String,
                     recencyRank: [String: Int],
                     limit: Int) -> [String]
    {
        guard !needle.isEmpty, limit > 0 else { return [] }

        struct Scored {
            var candidate: String
            var score: Int
            var recency: Int
        }

        var scored: [Scored] = []
        scored.reserveCapacity(candidates.count)
        for c in candidates {
            guard let s = subsequenceScore(needle: needle, haystack: c) else { continue }
            scored.append(Scored(
                candidate: c,
                score: s,
                recency: recencyRank[c] ?? Int.max))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.recency != b.recency { return a.recency < b.recency }
            return a.candidate < b.candidate
        }
        if scored.count > limit {
            return scored.prefix(limit).map(\.candidate)
        }
        return scored.map(\.candidate)
    }
}
