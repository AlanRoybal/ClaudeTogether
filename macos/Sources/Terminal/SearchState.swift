import Foundation
import CollabTermC

struct SearchMatch: Equatable {
    var row: Int
    var colStart: Int
    var length: Int
}

@MainActor
final class SearchState: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var query: String = ""
    @Published var matches: [SearchMatch] = []
    @Published var currentMatchIndex: Int? = nil

    func scan(grid: GridModel) {
        guard !query.isEmpty else {
            matches = []
            currentMatchIndex = nil
            return
        }

        let snap = grid.snapshot()
        let cols = Int(grid.cols)
        let rows = Int(grid.rows)
        guard cols > 0, rows > 0, snap.count >= cols * rows else {
            matches = []
            currentMatchIndex = nil
            return
        }

        let lowercasedQuery = query.lowercased()
        var found: [SearchMatch] = []

        for r in 0..<rows {
            // Build text for this row and a char-index → col mapping.
            var rowText = ""
            var charToCol: [Int] = []   // charToCol[charIndex] = col
            for c in 0..<cols {
                let cell = snap[r * cols + c]
                if cell.width == 0 { continue }     // trailing wide-glyph half
                let cp = cell.codepoint
                if cp == 0 {
                    rowText.append(" ")
                } else if let scalar = UnicodeScalar(cp) {
                    rowText.append(Character(scalar))
                } else {
                    rowText.append(" ")
                }
                charToCol.append(c)
            }

            let lowered = rowText.lowercased()
            var searchStart = lowered.startIndex
            while searchStart < lowered.endIndex {
                guard let range = lowered.range(of: lowercasedQuery, range: searchStart..<lowered.endIndex) else {
                    break
                }
                let charOffset = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
                let charLen    = lowercasedQuery.count
                if charOffset < charToCol.count {
                    let colStart = charToCol[charOffset]
                    // Span in cells: from charOffset to charOffset+charLen-1,
                    // clamped to the available mapping.
                    let lastCharIdx = min(charOffset + charLen - 1, charToCol.count - 1)
                    let colEnd = charToCol[lastCharIdx]
                    let cellLen = colEnd - colStart + 1
                    found.append(SearchMatch(row: r, colStart: colStart, length: max(1, cellLen)))
                }
                guard let next = lowered.index(range.lowerBound, offsetBy: 1, limitedBy: lowered.endIndex) else {
                    break
                }
                searchStart = next
            }
        }

        matches = found
        if found.isEmpty {
            currentMatchIndex = nil
        } else if let prev = currentMatchIndex {
            currentMatchIndex = min(prev, found.count - 1)
        } else {
            currentMatchIndex = 0
        }
    }

    func selectNext() {
        guard !matches.isEmpty else { return }
        if let idx = currentMatchIndex {
            currentMatchIndex = (idx + 1) % matches.count
        } else {
            currentMatchIndex = 0
        }
    }

    func selectPrev() {
        guard !matches.isEmpty else { return }
        if let idx = currentMatchIndex {
            currentMatchIndex = (idx - 1 + matches.count) % matches.count
        } else {
            currentMatchIndex = matches.count - 1
        }
    }

    func close() {
        isVisible = false
        matches = []
        currentMatchIndex = nil
    }
}
