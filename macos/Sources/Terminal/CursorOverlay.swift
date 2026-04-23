import Foundation
import simd

/// Builds the draw data for per-user cursor rectangles. The renderer owns the
/// Metal state; this module only decides *what* to draw.
///
/// Rendering model:
///   - Every participant gets a colored block rendered in the cursor pass.
///   - If multiple users land on the same cell, later blocks inset slightly so
///     they remain distinct instead of collapsing into a single fill.
///
/// All coordinates returned are grid cells; the renderer converts to pixels
/// via the existing `BgInstance` pipeline.
struct CursorOverlay {
    /// Blink period in seconds. Only the local block cursor blinks; peer
    /// blocks stay solid so remote activity is always visible.
    static let blinkPeriod: Double = 1.0

    struct BlockRect {
        var col: UInt16
        var row: UInt16
        /// Fractional cell offset and size, in (0..1) cell units. The renderer
        /// multiplies by `cellSize` to get pixels.
        var originFrac: SIMD2<Float>
        var sizeFrac: SIMD2<Float>
        var color: SIMD4<UInt8>
    }

    let blocks: [BlockRect]

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
        struct CellKey: Hashable {
            var col: UInt16
            var row: UInt16
        }

        let phase = fmod(time - blinkStart, blinkPeriod)
        let blinkOn = phase < blinkPeriod * 0.5
        var blocks: [BlockRect] = []
        var lanes: [CellKey: Int] = [:]

        for c in cursors {
            if c.isLocal && (!cursorVisible || !blinkOn) {
                continue
            }
            let key = CellKey(col: c.col, row: c.row)
            let lane = lanes[key, default: 0]
            lanes[key] = lane + 1
            blocks.append(blockRect(
                col: c.col,
                row: c.row,
                color: unpackRGBA(c.color),
                lane: lane))
        }
        return CursorOverlay(blocks: blocks)
    }

    // MARK: - Block geometry

    private static let baseAlpha: UInt8 = 200
    private static let laneInsetStep: Float = 0.12
    private static let maxInset: Float = 0.30

    private static func blockRect(
        col: UInt16,
        row: UInt16,
        color: SIMD4<UInt8>,
        lane: Int
    ) -> BlockRect {
        let inset = min(Float(lane) * laneInsetStep, maxInset)
        return BlockRect(
            col: col,
            row: row,
            originFrac: SIMD2<Float>(repeating: inset),
            sizeFrac: SIMD2<Float>(repeating: max(0.0, 1.0 - inset * 2.0)),
            color: SIMD4<UInt8>(color.x, color.y, color.z, baseAlpha))
    }

    private static func unpackRGBA(_ packed: UInt32) -> SIMD4<UInt8> {
        SIMD4<UInt8>(
            UInt8((packed >> 16) & 0xFF),
            UInt8((packed >>  8) & 0xFF),
            UInt8( packed        & 0xFF),
            255)
    }
}
