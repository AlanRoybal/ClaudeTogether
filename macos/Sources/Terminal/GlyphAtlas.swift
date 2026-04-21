import AppKit
import CoreText
import Metal

/// Alpha-8 glyph atlas. Each glyph is packed into a *tight* box (per-glyph
/// bounding rect from CoreText), not a cell-sized slot. Callers get the
/// atlas UV, pixel size, and per-glyph bearings needed to position the
/// quad inside its cell.
///
/// Layout recipe (cribbed from Ghostty's `src/font/face/coretext.zig`):
///   * No CTM Y-flip. CG's default is origin-bottom-left, but the pixel
///     buffer is stored row-0-at-top in memory. Drawing the glyph at
///     `textPosition = (-rect.origin.x, -rect.origin.y)` puts the glyph's
///     bbox bottom-left at CG (0, 0), which lands at the last row of
///     memory; the glyph's top lands at row 0. That's exactly how Metal
///     textures want their data.
final class GlyphAtlas {
    struct Entry {
        let atlasX: Int
        let atlasY: Int
        let pixelW: Int
        let pixelH: Int
        let bearingX: Int    // distance from cell-left to glyph-left, in pixels
        let bearingYTop: Int // distance from cell-bottom to glyph-top, in pixels
        let cellsWide: Int
    }

    let texture: MTLTexture
    let atlasWidthPx: Int
    let atlasHeightPx: Int

    let cellWidthPx: Int
    let cellHeightPx: Int
    let cellBaselinePx: Int // distance from cell-bottom up to baseline, in pixels

    let scale: CGFloat
    let font: CTFont

    private let device: MTLDevice
    private var shelfX: Int = 0
    private var shelfY: Int = 0
    private var shelfH: Int = 0
    private let padding: Int = 1

    private var cache: [UInt32: Entry] = [:]

    init?(device: MTLDevice,
          pointSize: CGFloat = 13,
          scale: CGFloat = 2,
          atlasSize: Int = 2048)
    {
        self.device = device
        self.scale = scale
        self.atlasWidthPx = atlasSize
        self.atlasHeightPx = atlasSize

        let nsFont = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        let font = nsFont as CTFont

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let cellHPt = ceil(ascent + descent + leading)

        // Measure advance using 'M' (monospaced → all glyphs share it).
        var mGlyph: CGGlyph = 0
        var mChar: UniChar = UniChar("M".utf16.first!)
        _ = withUnsafePointer(to: &mChar) { c in
            withUnsafeMutablePointer(to: &mGlyph) { g in
                CTFontGetGlyphsForCharacters(font, c, g, 1)
            }
        }
        var adv = CGSize.zero
        _ = withUnsafePointer(to: &mGlyph) { g in
            withUnsafeMutablePointer(to: &adv) { a in
                CTFontGetAdvancesForGlyphs(font, .horizontal, g, a, 1)
            }
        }
        let cellWPt = adv.width > 0 ? adv.width : pointSize * 0.6

        self.font = font
        self.cellWidthPx = max(1, Int(ceil(cellWPt * scale)))
        self.cellHeightPx = max(1, Int(ceil(cellHPt * scale)))
        self.cellBaselinePx = max(0, Int(round((descent + leading / 2) * scale)))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasSize,
            height: atlasSize,
            mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        self.texture = tex
    }

    func entry(for codepoint: UInt32, cellsWide: Int) -> Entry? {
        if let hit = cache[codepoint] { return hit }
        guard let e = rasterize(codepoint: codepoint, cellsWide: cellsWide) else {
            return nil
        }
        cache[codepoint] = e
        return e
    }

    private func rasterize(codepoint: UInt32, cellsWide: Int) -> Entry? {
        // Build a CTLine so shaping + font fallback works for both plain
        // codepoints and surrogate-pair codepoints (emoji).
        let str: String
        if let u = Unicode.Scalar(codepoint) { str = String(u) }
        else { str = "\u{FFFD}" }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: str, attributes: attrs))
        // Tight glyph-path bounds in points. Origin-Y is the baseline.
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        if bounds.size.width < 0.25 || bounds.size.height < 0.25 {
            return Entry(atlasX: 0, atlasY: 0,
                         pixelW: 0, pixelH: 0,
                         bearingX: 0, bearingYTop: 0,
                         cellsWide: cellsWide)
        }

        // Pixel-space size (ceil so the bitmap fully contains the glyph).
        let pxW = max(1, Int(ceil(bounds.size.width * scale)))
        let pxH = max(1, Int(ceil(bounds.size.height * scale)))

        // Reserve a slot in the atlas (shelf packer).
        guard let (ax, ay) = reserve(w: pxW, h: pxH) else { return nil }

        // Allocate a tight per-glyph buffer.
        let bytesPerRow = pxW
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * pxH)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            guard let ctx = CGContext(
                data: base,
                width: pxW,
                height: pxH,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return }
            ctx.setShouldAntialias(true)
            ctx.setAllowsFontSmoothing(true)
            ctx.setShouldSmoothFonts(true)
            ctx.setAllowsFontSubpixelPositioning(true)
            ctx.setShouldSubpixelPositionFonts(true)
            ctx.setAllowsFontSubpixelQuantization(false)
            ctx.setShouldSubpixelQuantizeFonts(false)
            ctx.textMatrix = .identity
            // Scale CoreText drawing from points to pixels.
            ctx.scaleBy(x: scale, y: scale)
            // Put the glyph's bbox bottom-left at CG (0, 0). Because CG is
            // y-up but the memory layout is row-0-at-top, this lands the
            // glyph's top row at memory row 0 — which is where Metal
            // expects it when sampling with (u=0, v=0) at the top-left.
            ctx.textPosition = CGPoint(
                x: -bounds.origin.x,
                y: -bounds.origin.y)
            CTLineDraw(line, ctx)
        }

        // Upload.
        let region = MTLRegionMake2D(ax, ay, pxW, pxH)
        bytes.withUnsafeBytes { raw in
            texture.replace(region: region,
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: bytesPerRow)
        }

        // Bearings, in pixels.
        let bearingX = Int(floor(bounds.origin.x * scale))
        // y in points from cell-bottom up to top of glyph = baseline + (origin.y + height).
        let topAboveBaselinePt = bounds.origin.y + bounds.size.height
        let bearingYTop = cellBaselinePx + Int(ceil(topAboveBaselinePt * scale))

        return Entry(atlasX: ax, atlasY: ay,
                     pixelW: pxW, pixelH: pxH,
                     bearingX: bearingX, bearingYTop: bearingYTop,
                     cellsWide: cellsWide)
    }

    private func reserve(w: Int, h: Int) -> (Int, Int)? {
        let need = w + padding
        if shelfX + need > atlasWidthPx {
            shelfY += shelfH
            shelfX = 0
            shelfH = 0
        }
        if shelfY + h + padding > atlasHeightPx { return nil }
        let ox = shelfX
        let oy = shelfY
        shelfX += need
        if h + padding > shelfH { shelfH = h + padding }
        return (ox, oy)
    }
}
