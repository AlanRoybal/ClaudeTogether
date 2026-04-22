import Foundation
import simd

/// Builds the draw data for per-user cursor rectangles. The renderer owns the
/// Metal state; this module only decides *what* to draw.
///
/// Rendering model:
///   - The local block cursor is rendered by swapping the cell's fg/bg in the
///     text/bg passes (crisp, readable, doesn't occlude the glyph).
///   - Peer cursors are rendered as a 4-rect colored border around the cell,
///     so multiple peers on the same cell remain visible without hiding text.
///
/// All coordinates returned are grid cells; the renderer converts to pixels
/// via the existing `BgInstance` pipeline.
struct CursorOverlay {
    /// Blink period in seconds. Only the local block cursor blinks; peer
    /// borders stay solid so remote activity is always visible.
    static let blinkPeriod: Double = 1.0

    struct BorderRect {
        var col: UInt16
        var row: UInt16
        /// Fractional cell offset and size, in (0..1) cell units. The renderer
        /// multiplies by `cellSize` to get pixels.
        var originFrac: SIMD2<Float>
        var sizeFrac: SIMD2<Float>
        var color: SIMD4<UInt8>
    }

    /// (col, row) of the local cursor, only when it should render as an
    /// inverted block this frame (i.e. blink-on and visible). `nil` otherwise.
    let localBlockCell: (UInt16, UInt16)?

    /// One entry per peer cursor. The renderer should emit 4 thin BgInstances
    /// per border (top/bottom/left/right), or use the fractional coords via
    /// a future dedicated pipeline.
    let peerBorders: [BorderRect]

    /// Build the overlay for the current frame.
    /// - Parameters:
    ///   - cursors: ordered list from `GridModel.cursors`.
    ///   - time: `CACurrentMediaTime()` for blink phase.
    ///   - blinkOn: caller-controlled override (false disables local blink).
    static func build(
        cursors: [UserCursor],
        time: Double,
        blinkStart: Double,
        cursorVisible: Bool
    ) -> CursorOverlay {
        var local: (UInt16, UInt16)? = nil
        var peers: [BorderRect] = []

        let phase = fmod(time - blinkStart, blinkPeriod)
        let blinkOn = phase < blinkPeriod * 0.5

        for c in cursors {
            if c.isLocal {
                if cursorVisible && blinkOn {
                    local = (c.col, c.row)
                }
            } else {
                let color = unpackRGBA(c.color)
                peers.append(contentsOf: borderRects(
                    col: c.col, row: c.row, color: color))
            }
        }
        return CursorOverlay(localBlockCell: local, peerBorders: peers)
    }

    /// True if the cell at (x,y) is the local block cursor this frame.
    func isLocalBlockCell(x: Int, y: Int) -> Bool {
        guard let (cx, cy) = localBlockCell else { return false }
        return Int(cx) == x && Int(cy) == y
    }

    // MARK: - Border geometry

    /// 2/cell thickness (expressed as a fraction of the cell). The renderer
    /// scales by cellSize so thickness is in pixels proportional to cell.
    private static let borderThick: Float = 0.12

    private static func borderRects(
        col: UInt16, row: UInt16, color: SIMD4<UInt8>
    ) -> [BorderRect] {
        let t = borderThick
        // top, bottom, left, right
        return [
            BorderRect(col: col, row: row,
                originFrac: SIMD2(0, 0),      sizeFrac: SIMD2(1, t),
                color: color),
            BorderRect(col: col, row: row,
                originFrac: SIMD2(0, 1 - t),  sizeFrac: SIMD2(1, t),
                color: color),
            BorderRect(col: col, row: row,
                originFrac: SIMD2(0, t),      sizeFrac: SIMD2(t, 1 - 2 * t),
                color: color),
            BorderRect(col: col, row: row,
                originFrac: SIMD2(1 - t, t),  sizeFrac: SIMD2(t, 1 - 2 * t),
                color: color),
        ]
    }

    private static func unpackRGBA(_ packed: UInt32) -> SIMD4<UInt8> {
        SIMD4<UInt8>(
            UInt8((packed >> 16) & 0xFF),
            UInt8((packed >>  8) & 0xFF),
            UInt8( packed        & 0xFF),
            255)
    }
}
