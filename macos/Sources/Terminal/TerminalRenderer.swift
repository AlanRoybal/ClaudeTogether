import AppKit
import Metal
import MetalKit
import simd
import CollabTermC

/// Matches `BgInstance` in Shaders.metal exactly: ushort2 + uchar4 = 8 bytes.
/// The struct MUST stay 8 bytes — Metal reads instanced buffers at sizeof(BgInstance)
/// strides on the GPU side, so any extra padding here would misalign every instance
/// after the first and produce a checkerboard artefact.
struct BgInstance {
    var gridPos: SIMD2<UInt16> = .zero
    var color: SIMD4<UInt8> = .zero
}

/// Matches `CursorInstance` in Shaders.metal.
struct CursorInstance {
    var gridPos: SIMD2<UInt16> = .zero
    var _pad0: (UInt16, UInt16) = (0, 0)
    var originFrac: SIMD2<Float> = .zero
    var sizeFrac: SIMD2<Float> = .zero
    var color: SIMD4<UInt8> = .zero
    var _pad1: (UInt32) = (0)
}

/// Matches `TextInstance` in Shaders.metal.
struct TextInstance {
    var gridPos: SIMD2<UInt16> = .zero
    var offset: SIMD2<Int16> = .zero
    var glyphSize: SIMD2<UInt16> = .zero
    var uvOrigin: SIMD2<Float> = .zero
    var uvSize: SIMD2<Float> = .zero
    var fg: SIMD4<UInt8> = .zero
    var _pad: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
}

struct RendererUniforms {
    var viewportSize: SIMD2<Float>
    var cellSize: SIMD2<Float>
}

/// Two-pass Metal terminal renderer. Pass 1 paints each cell's bg. Pass 2
/// draws glyph-sized quads at per-glyph bearings with standard alpha blend.
final class TerminalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private(set) var atlas: GlyphAtlas
    private let commandQueue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let textPipeline: MTLRenderPipelineState
    private let cursorPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private var bgBuffer: MTLBuffer?
    private var bgCapacity: Int = 0
    private var textBuffer: MTLBuffer?
    private var textCapacity: Int = 0
    private var cursorTextBuffer: MTLBuffer?
    private var cursorTextCapacity: Int = 0
    private var cursorBuffer: MTLBuffer?
    private var cursorCapacity: Int = 0

    weak var view: MTKView?
    var grid: GridModel?

    private(set) var theme: TerminalTheme = .defaultDark
    private var fgColorMap: [UInt32: UInt32] = [:]
    private var bgColorMap: [UInt32: UInt32] = [:]

    private(set) var cols: UInt16 = 80
    private(set) var rows: UInt16 = 24

    /// Live point size for the glyph atlas. Use `setPointSize(_:)` to change
    /// at runtime — the atlas is rebuilt and the grid is re-measured.
    private(set) var pointSize: CGFloat = 13

    /// Cell size in view points (NOT pixels). MetalTerminalNSView uses this
    /// to translate `event.locationInWindow` → grid (col, row) for mouse
    /// reporting. Returns the atlas pixel size divided by the view's backing
    /// scale; falls back to 1.0 scale when no view/window is attached.
    var cellSize: CGSize {
        let scale: CGFloat
        if let v = view {
            scale = v.window?.backingScaleFactor
                ?? v.window?.screen?.backingScaleFactor
                ?? atlas.scale
        } else {
            scale = atlas.scale
        }
        let denom = max(scale, 0.0001)
        return CGSize(
            width: CGFloat(atlas.cellWidthPx) / denom,
            height: CGFloat(atlas.cellHeightPx) / denom)
    }

    var onResize: ((UInt16, UInt16) -> Void)?

    var cursorVisible = true
    private var blinkStart = CACurrentMediaTime()

    /// Normalized selection range set by the view layer. Both endpoints are
    /// inclusive and `start` is always <= `end` (row-major order).
    var selection: (start: (col: Int, row: Int), end: (col: Int, row: Int))? = nil

    init?(view: MTKView, pointSize: CGFloat = 13) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            return nil
        }
        view.device = device
        self.device = device

        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        // Backing scale has to match the drawable's backing scale (not the
        // layer's contentsScale — that's 1.0 until the view is on-window).
        let scale = view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        guard let atlas = GlyphAtlas(device: device, pointSize: pointSize, scale: scale) else {
            return nil
        }
        self.atlas = atlas
        self.pointSize = pointSize

        guard let library = device.makeDefaultLibrary(),
              let bgV = library.makeFunction(name: "bg_vertex"),
              let bgF = library.makeFunction(name: "bg_fragment"),
              let tV  = library.makeFunction(name: "text_vertex"),
              let tF  = library.makeFunction(name: "text_fragment"),
              let cV  = library.makeFunction(name: "cursor_vertex"),
              let cF  = library.makeFunction(name: "cursor_fragment")
        else { return nil }

        let fmt = view.colorPixelFormat
        do {
            let bgDesc = MTLRenderPipelineDescriptor()
            bgDesc.vertexFunction = bgV
            bgDesc.fragmentFunction = bgF
            bgDesc.colorAttachments[0].pixelFormat = fmt
            self.bgPipeline = try device.makeRenderPipelineState(descriptor: bgDesc)

            let tDesc = MTLRenderPipelineDescriptor()
            tDesc.vertexFunction = tV
            tDesc.fragmentFunction = tF
            tDesc.colorAttachments[0].pixelFormat = fmt
            let att = tDesc.colorAttachments[0]!
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .sourceAlpha
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.textPipeline = try device.makeRenderPipelineState(descriptor: tDesc)

            let cDesc = MTLRenderPipelineDescriptor()
            cDesc.vertexFunction = cV
            cDesc.fragmentFunction = cF
            cDesc.colorAttachments[0].pixelFormat = fmt
            let cAtt = cDesc.colorAttachments[0]!
            cAtt.isBlendingEnabled = true
            cAtt.rgbBlendOperation = .add
            cAtt.alphaBlendOperation = .add
            cAtt.sourceRGBBlendFactor = .sourceAlpha
            cAtt.destinationRGBBlendFactor = .oneMinusSourceAlpha
            cAtt.sourceAlphaBlendFactor = .sourceAlpha
            cAtt.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.cursorPipeline = try device.makeRenderPipelineState(descriptor: cDesc)
        } catch {
            NSLog("pipeline failed: \(error)")
            return nil
        }

        let sDesc = MTLSamplerDescriptor()
        sDesc.minFilter = .linear
        sDesc.magFilter = .linear
        sDesc.sAddressMode = .clampToEdge
        sDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sDesc) else {
            return nil
        }
        self.sampler = sampler

        super.init()
        self.view = view
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        setTheme(.defaultDark)
    }

    func setTheme(_ newTheme: TerminalTheme) {
        theme = newTheme
        fgColorMap = newTheme.fgColorMap
        bgColorMap = newTheme.bgColorMap
        let bg = newTheme.background
        view?.clearColor = MTLClearColor(
            red:   Double((bg >> 16) & 0xFF) / 255,
            green: Double((bg >>  8) & 0xFF) / 255,
            blue:  Double( bg        & 0xFF) / 255,
            alpha: 1)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // If the actual backing scale differs from what the atlas was
        // built with (e.g. moved to a different screen), rebuild.
        if view.bounds.width > 0 {
            let actual = size.width / view.bounds.width
            if abs(actual - atlas.scale) > 0.1,
               let newAtlas = GlyphAtlas(device: device,
                                         pointSize: pointSize,
                                         scale: actual)
            {
                self.atlas = newAtlas
            }
        }
        recomputeGrid(for: size)
    }

    /// Rebuild the glyph atlas at a new point size and re-measure the grid
    /// so the renderer (and PTY, via `onResize`) catch up immediately.
    /// Called by `MetalTerminalView` whenever the SwiftUI side advertises a
    /// new font size from the menu.
    func setPointSize(_ newPointSize: CGFloat) {
        guard newPointSize > 0, newPointSize != pointSize else { return }
        pointSize = newPointSize
        let scale = view?.window?.backingScaleFactor
            ?? atlas.scale
        if let newAtlas = GlyphAtlas(device: device,
                                     pointSize: newPointSize,
                                     scale: scale)
        {
            self.atlas = newAtlas
        }
        if let v = view {
            recomputeGrid(for: v.drawableSize)
            v.setNeedsDisplay(v.bounds)
        }
    }

    func draw(in view: MTKView) {
        guard let grid = grid,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer()
        else { return }

        let snap = grid.snapshot()
        let now = CACurrentMediaTime()
        let overlay = CursorOverlay.build(
            cursors: grid.cursors,
            time: now,
            blinkStart: blinkStart,
            cursorVisible: cursorVisible,
            localCursorColor: unpack(theme.foreground))

        let cellW = Float(atlas.cellWidthPx)
        let cellH = Float(atlas.cellHeightPx)
        let cols = Int(self.cols)
        let rows = Int(self.rows)
        let cellCount = cols * rows

        var bgInstances: [BgInstance] = []
        var textInstances: [TextInstance] = []
        var cursorTextInstances: [TextInstance] = []
        bgInstances.reserveCapacity(cellCount)
        textInstances.reserveCapacity(cellCount)
        cursorTextInstances.reserveCapacity(overlay.rects.count)

        let selectionSnapshot = selection   // snapshot so rendering is consistent
        let selectionColor = unpack(theme.selectionBg)

        if snap.count >= cellCount {
            let atlasW = Float(atlas.atlasWidthPx)
            let atlasH = Float(atlas.atlasHeightPx)
            for y in 0..<rows {
                for x in 0..<cols {
                    let c = snap[y * cols + x]
                    // width==0 marks the trailing half of a CJK wide glyph.
                    // We still emit a BG quad for every cell so selection
                    // highlighting is solid; only the text glyph pass skips
                    // trailing halves.
                    let fg = unpack(fgColorMap[c.fg] ?? c.fg)
                    let bg = unpack(bgColorMap[c.bg] ?? c.bg)

                    // BG: render the terminal's actual background. Colored
                    // collaborator blocks are composited in the cursor pass.
                    var bi = BgInstance()
                    bi.gridPos = SIMD2<UInt16>(UInt16(x), UInt16(y))
                    bi.color = selectionSnapshot.map { isCellSelected(col: x, row: y, sel: $0) ? selectionColor : bg } ?? bg
                    bgInstances.append(bi)

                    // TEXT: skip wide-glyph trailing halves and blanks.
                    if c.width == 0 { continue }
                    if let ti = makeTextInstance(
                        cell: c,
                        col: UInt16(x),
                        row: UInt16(y),
                        color: fg,
                        atlasW: atlasW,
                        atlasH: atlasH)
                    {
                        textInstances.append(ti)
                    }
                }
            }

            var cursorCells: [Int: CursorOverlay.Rect] = [:]
            cursorCells.reserveCapacity(overlay.rects.count)
            for block in overlay.rects {
                let index = Int(block.row) * cols + Int(block.col)
                guard index >= 0, index < snap.count else { continue }
                cursorCells[index] = block
            }
            for (index, block) in cursorCells {
                let cell = snap[index]
                guard let ti = makeTextInstance(
                    cell: cell,
                    col: block.col,
                    row: block.row,
                    color: cursorTextColor(on: block.color),
                    atlasW: atlasW,
                    atlasH: atlasH)
                else {
                    continue
                }
                cursorTextInstances.append(ti)
            }
        }

        // Full colored block cursors for all visible collaborators.
        var cursorInstances: [CursorInstance] = []
        cursorInstances.reserveCapacity(overlay.rects.count)
        for r in overlay.rects {
            var ci = CursorInstance()
            ci.gridPos = SIMD2<UInt16>(r.col, r.row)
            ci.originFrac = r.originFrac
            ci.sizeFrac = r.sizeFrac
            ci.color = r.color
            cursorInstances.append(ci)
        }

        ensureBgCapacity(bgInstances.count)
        ensureTextCapacity(textInstances.count)
        ensureCursorTextCapacity(cursorTextInstances.count)
        ensureCursorCapacity(cursorInstances.count)
        if !bgInstances.isEmpty, let bgBuf = bgBuffer {
            bgInstances.withUnsafeBytes { raw in
                _ = memcpy(bgBuf.contents(), raw.baseAddress!, raw.count)
            }
        }
        if !textInstances.isEmpty, let tBuf = textBuffer {
            textInstances.withUnsafeBytes { raw in
                _ = memcpy(tBuf.contents(), raw.baseAddress!, raw.count)
            }
        }
        if !cursorTextInstances.isEmpty, let cursorTextBuf = cursorTextBuffer {
            cursorTextInstances.withUnsafeBytes { raw in
                _ = memcpy(cursorTextBuf.contents(), raw.baseAddress!, raw.count)
            }
        }
        if !cursorInstances.isEmpty, let cBuf = cursorBuffer {
            cursorInstances.withUnsafeBytes { raw in
                _ = memcpy(cBuf.contents(), raw.baseAddress!, raw.count)
            }
        }

        var uniforms = RendererUniforms(
            viewportSize: SIMD2<Float>(
                Float(view.drawableSize.width),
                Float(view.drawableSize.height)),
            cellSize: SIMD2<Float>(cellW, cellH))

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        // Pass 1: BG
        if !bgInstances.isEmpty, let bgBuf = bgBuffer {
            enc.setRenderPipelineState(bgPipeline)
            enc.setVertexBuffer(bgBuf, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<RendererUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: bgInstances.count)
        }

        // Pass 2: TEXT
        if !textInstances.isEmpty, let tBuf = textBuffer {
            enc.setRenderPipelineState(textPipeline)
            enc.setVertexBuffer(tBuf, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<RendererUniforms>.stride, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: textInstances.count)
        }

        // Pass 3: CURSOR (colored participant blocks)
        if !cursorInstances.isEmpty, let cBuf = cursorBuffer {
            enc.setRenderPipelineState(cursorPipeline)
            enc.setVertexBuffer(cBuf, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<RendererUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: cursorInstances.count)
        }

        // Pass 4: redraw any glyph under a block cursor in a contrasting color
        // so fully colored cursors still leave typed text legible.
        if !cursorTextInstances.isEmpty, let cursorTextBuf = cursorTextBuffer {
            enc.setRenderPipelineState(textPipeline)
            enc.setVertexBuffer(cursorTextBuf, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<RendererUniforms>.stride, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: cursorTextInstances.count)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: helpers

    func recomputeGrid(for drawableSize: CGSize) {
        let cw = max(1, atlas.cellWidthPx)
        let ch = max(1, atlas.cellHeightPx)
        let cols = max(1, Int(drawableSize.width) / cw)
        let rows = max(1, Int(drawableSize.height) / ch)
        let newCols = UInt16(min(Int(UInt16.max), cols))
        let newRows = UInt16(min(Int(UInt16.max), rows))
        if newCols != self.cols || newRows != self.rows {
            self.cols = newCols
            self.rows = newRows
            onResize?(newCols, newRows)
        }
    }

    private func ensureBgCapacity(_ n: Int) {
        if n <= bgCapacity { return }
        let cap = max(n, 1024)
        bgBuffer = device.makeBuffer(
            length: cap * MemoryLayout<BgInstance>.stride,
            options: [.storageModeShared])
        bgCapacity = cap
    }

    private func ensureTextCapacity(_ n: Int) {
        if n <= textCapacity { return }
        let cap = max(n, 1024)
        textBuffer = device.makeBuffer(
            length: cap * MemoryLayout<TextInstance>.stride,
            options: [.storageModeShared])
        textCapacity = cap
    }

    private func ensureCursorTextCapacity(_ n: Int) {
        if n <= cursorTextCapacity { return }
        let cap = max(n, 64)
        cursorTextBuffer = device.makeBuffer(
            length: cap * MemoryLayout<TextInstance>.stride,
            options: [.storageModeShared])
        cursorTextCapacity = cap
    }

    private func ensureCursorCapacity(_ n: Int) {
        if n <= cursorCapacity { return }
        let cap = max(n, 16)
        cursorBuffer = device.makeBuffer(
            length: cap * MemoryLayout<CursorInstance>.stride,
            options: [.storageModeShared])
        cursorCapacity = cap
    }

    /// 0xRRGGBB (u32) → RGBA uchar4 (alpha = 255).
    private func unpack(_ packed: UInt32) -> SIMD4<UInt8> {
        return SIMD4<UInt8>(
            UInt8((packed >> 16) & 0xFF),
            UInt8((packed >>  8) & 0xFF),
            UInt8( packed        & 0xFF),
            255)
    }

    private func makeTextInstance(
        cell: ct_cell,
        col: UInt16,
        row: UInt16,
        color: SIMD4<UInt8>,
        atlasW: Float,
        atlasH: Float
    ) -> TextInstance? {
        let cp = cell.codepoint
        if cell.width == 0 || cp == 0 || cp == 0x20 {
            return nil
        }
        let cw = Int(max(cell.width, 1))
        guard let entry = atlas.entry(for: cp, cellsWide: cw),
              entry.pixelW > 0, entry.pixelH > 0
        else {
            return nil
        }

        var ti = TextInstance()
        ti.gridPos = SIMD2<UInt16>(col, row)
        ti.offset = SIMD2<Int16>(
            Int16(entry.bearingX),
            Int16(atlas.cellHeightPx - entry.bearingYTop))
        ti.glyphSize = SIMD2<UInt16>(
            UInt16(entry.pixelW),
            UInt16(entry.pixelH))
        ti.uvOrigin = SIMD2<Float>(
            Float(entry.atlasX) / atlasW,
            Float(entry.atlasY) / atlasH)
        ti.uvSize = SIMD2<Float>(
            Float(entry.pixelW) / atlasW,
            Float(entry.pixelH) / atlasH)
        ti.fg = color
        return ti
    }

    private func isCellSelected(
        col: Int, row: Int,
        sel: (start: (col: Int, row: Int), end: (col: Int, row: Int))
    ) -> Bool {
        let s = sel.start, e = sel.end
        if row < s.row || row > e.row { return false }
        if s.row == e.row { return col >= s.col && col <= e.col }
        if row == s.row { return col >= s.col }
        if row == e.row { return col <= e.col }
        return true
    }

    private func cursorTextColor(on cursorColor: SIMD4<UInt8>) -> SIMD4<UInt8> {
        let luminance = (
            0.2126 * Double(cursorColor.x) +
            0.7152 * Double(cursorColor.y) +
            0.0722 * Double(cursorColor.z)
        ) / 255.0
        return luminance < 0.45
            ? SIMD4<UInt8>(245, 247, 250, 255)
            : SIMD4<UInt8>(17, 17, 17, 255)
    }

}
