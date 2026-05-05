import Foundation
import simd

/// Builds the draw data for per-user cursor rectangles. The renderer owns the
/// Metal state; this module only decides *what* to draw.
///
/// Rendering model:
///   - Every participant gets a fully colored block cursor rendered in the
///     cursor pass.
///   - Each cursor fills the entire terminal cell, matching a normal terminal
///     block cursor.
///
/// All coordinates returned are grid cells; the renderer converts to pixels
/// via the existing `BgInstance` pipeline.
struct CursorOverlay {
    /// Blink period in seconds. Only the local block blinks; peer blocks stay
    /// solid so remote activity is always visible.
    static let blinkPeriod: Double = 1.0

    struct Rect {
        var col: UInt16
        var row: UInt16
        /// Fractional cell offset and size, in (0..1) cell units. The renderer
        /// multiplies by `cellSize` to get pixels.
        var originFrac: SIMD2<Float>
        var sizeFrac: SIMD2<Float>
        var color: SIMD4<UInt8>
    }

    let rects: [Rect]

    /// Build the overlay for the current frame.
    /// - Parameters:
    ///   - cursors: ordered list from `GridModel.cursors`.
    ///   - time: `CACurrentMediaTime()` for blink phase.
    ///   - cursorVisible: caller-controlled override for the local block.
    static func build(
        cursors: [UserCursor],
        time: Double,
        blinkStart: Double,
        cursorVisible: Bool
    ) -> CursorOverlay {
        let phase = fmod(time - blinkStart, blinkPeriod)
        let blinkOn = phase < blinkPeriod * 0.5
        var rects: [Rect] = []

        for c in cursors {
            if c.isLocal && (!cursorVisible || !blinkOn) {
                continue
            }
            rects.append(blockRect(
                col: c.col,
                row: c.row,
                color: unpackRGBA(c.color)))
        }
        return CursorOverlay(rects: rects)
    }

    // MARK: - Block geometry

    private static func blockRect(col: UInt16,
                                  row: UInt16,
                                  color: SIMD4<UInt8>) -> Rect
    {
        Rect(
            col: col,
            row: row,
            originFrac: SIMD2<Float>(0, 0),
            sizeFrac: SIMD2<Float>(1, 1),
            color: color)
    }

    private static func unpackRGBA(_ packed: UInt32) -> SIMD4<UInt8> {
        SIMD4<UInt8>(
            UInt8((packed >> 16) & 0xFF),
            UInt8((packed >>  8) & 0xFF),
            UInt8( packed        & 0xFF),
            255)
    }
}
