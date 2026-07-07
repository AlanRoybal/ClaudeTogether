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
    /// Minimum WCAG contrast ratio enforced between glyph foreground and its
    /// cell background. Apps that draw their own blocks (e.g. Claude Code's
    /// user-message bar) often pick a fixed dark background but leave the text
    /// at the terminal default foreground; on a light theme that default maps
    /// to a dark color, leaving the text dark-on-dark. Lifting the foreground
    /// to meet this floor keeps such text legible on every theme — and because
    /// it runs per-renderer, each participant in a shared session gets it
    /// applied against their own theme. 1.0 disables it.
    var minimumContrastRatio: Double = 3.0
    /// Cache of (themedFg, themedBg) → contrast-adjusted fg so the per-cell
    /// floor doesn't re-run the search every frame. Cleared when the theme
    /// changes (the themed keys change with it).
    private var contrastAdjustCache: [UInt64: UInt32] = [:]
    /// When true, neutral (grayscale) block backgrounds an app draws with the
    /// opposite light/dark polarity to the active theme — e.g. Claude Code's
    /// dark user-message bar shown on a light theme — are remapped to a subtle
    /// theme-derived highlight so the bar reads as native to the theme instead
    /// of a fixed dark/light strip. Runs per-renderer, so each participant in a
    /// shared session sees it resolved against their own theme.
    var adaptBlockBackgrounds: Bool = true
    /// Cache of themedBg → theme-adapted block background. Cleared on theme change.
    private var blockBgAdaptCache: [UInt32: UInt32] = [:]

    private(set) var cols: UInt16 = 80
    private(set) var rows: UInt16 = 24

    /// Live point size for the glyph atlas. Use `setPointSize(_:)` to change
    /// at runtime — the atlas is rebuilt and the grid is re-measured.
    private(set) var pointSize: CGFloat = 13

    /// PostScript font name passed to GlyphAtlas. Empty string = system monospace.
    /// Use `setFontName(_:)` to change at runtime.
    private(set) var fontName: String = ""

    /// When true the draw loop attempts ligature substitution for known
    /// programming sequences before falling back to individual-glyph rendering.
    // The didSet guards matter: SwiftUI re-runs updateNSView on every model
    // publish and re-assigns these properties wholesale, and an unconditional
    // seq bump would force a full GPU re-encode per SwiftUI pass even when
    // nothing changed.
    var ligaturesEnabled: Bool = true {
        didSet { if ligaturesEnabled != oldValue { rendererMutationSeq &+= 1 } }
    }

    private static let ligatureSequences: [String] = [
        // longest first so greedy matching picks the longest match
        "!==", "===", "<->", "<=>", ">>>", "<<<",
        "->",  "=>",  "<-",  "<|",  "|>",  "!=",
        "==",  ">=",  "<=",  "&&",  "||",  "??",
        "::",  "++",  "--",  "..",  "//",  "/*",
        "*/",  "**",  ">>",  "<<",
    ]
    private static let ligatureStarters: Set<UInt32> = {
        Set(ligatureSequences.compactMap { $0.unicodeScalars.first?.value })
    }()

    /// Sequences bucketed by first scalar, longest first, with the scalar
    /// values pre-extracted. The draw loop consults this per candidate cell;
    /// walking `ligatureSequences` and re-splitting each String there costs
    /// an allocation per sequence per cell per frame.
    private static let ligaturesByFirstScalar: [UInt32: [(seq: String, scalars: [UInt32])]] = {
        var table: [UInt32: [(seq: String, scalars: [UInt32])]] = [:]
        for seq in ligatureSequences {
            let scalars = seq.unicodeScalars.map(\.value)
            guard let first = scalars.first else { continue }
            table[first, default: []].append((seq, scalars))
        }
        return table
    }()

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

    var cursorVisible = true {
        didSet { if cursorVisible != oldValue { rendererMutationSeq &+= 1 } }
    }
    private var blinkStart = CACurrentMediaTime()

    /// Normalized selection range set by the view layer. Both endpoints are
    /// inclusive and `start` is always <= `end` (row-major order).
    var selection: (start: (col: Int, row: Int), end: (col: Int, row: Int))? = nil {
        didSet { rendererMutationSeq &+= 1 }
    }

    /// Current find-bar matches in viewport coordinates. Set by MetalTerminalView.
    var searchMatches: [SearchMatch] = [] {
        didSet { if searchMatches != oldValue { rendererMutationSeq &+= 1 } }
    }
    /// Index into `searchMatches` for the currently focused match, or nil.
    var currentMatchIndex: Int? = nil {
        didSet { if currentMatchIndex != oldValue { rendererMutationSeq &+= 1 } }
    }

    /// Bumped by any renderer-state setter that affects `draw(in:)` output but
    /// is not reflected in `GridModel.epoch` (selection, search, theme, font,
    /// cursor visibility, ligatures). Combined with `grid.epoch` and the
    /// quantised blink phase to gate redraws — see `draw(in:)`.
    private var rendererMutationSeq: UInt64 = 0
    private var lastDrawnGridEpoch: UInt32?
    private var lastDrawnMutationSeq: UInt64?
    private var lastDrawnBlinkPhase: Int?

    /// Guards the shared instance buffers against the CPU overwriting them
    /// while the previous frame's command buffer is still reading. The draw
    /// loop writes instances in place, so without this a fast second frame
    /// (heavy output on a ProMotion display) could tear the still-in-flight
    /// frame's geometry. value:1 = at most one frame in flight.
    private let inFlightSemaphore = DispatchSemaphore(value: 1)

    init?(view: MTKView, fontName: String = "", pointSize: CGFloat = 13) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            return nil
        }
        view.device = device
        self.device = device
        self.fontName = fontName

        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        // Backing scale has to match the drawable's backing scale (not the
        // layer's contentsScale — that's 1.0 until the view is on-window).
        let scale = view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        guard let atlas = GlyphAtlas(device: device,
                                     fontName: fontName.isEmpty ? nil : fontName,
                                     pointSize: pointSize,
                                     scale: scale) else {
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
        contrastAdjustCache.removeAll(keepingCapacity: true)
        blockBgAdaptCache.removeAll(keepingCapacity: true)
        let bg = newTheme.background
        view?.clearColor = MTLClearColor(
            red:   Double((bg >> 16) & 0xFF) / 255,
            green: Double((bg >>  8) & 0xFF) / 255,
            blue:  Double( bg        & 0xFF) / 255,
            alpha: 1)
        rendererMutationSeq &+= 1
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // If the actual backing scale differs from what the atlas was
        // built with (e.g. moved to a different screen), rebuild.
        if view.bounds.width > 0 {
            let actual = size.width / view.bounds.width
            if abs(actual - atlas.scale) > 0.1,
               let newAtlas = GlyphAtlas(device: device,
                                         fontName: fontName.isEmpty ? nil : fontName,
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
        rendererMutationSeq &+= 1
        let scale = view?.window?.backingScaleFactor
            ?? atlas.scale
        if let newAtlas = GlyphAtlas(device: device,
                                     fontName: fontName.isEmpty ? nil : fontName,
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

    /// Force a redraw on the next frame even though no grid/renderer mutation
    /// occurred — used when the live Cmd modifier toggles, which shows/hides
    /// OSC 8 link underlines.
    func requestRedraw() {
        rendererMutationSeq &+= 1
        if let v = view { v.setNeedsDisplay(v.bounds) }
    }

    func setFontName(_ newName: String) {
        guard newName != fontName else { return }
        fontName = newName
        rendererMutationSeq &+= 1
        let scale = view?.window?.backingScaleFactor ?? atlas.scale
        if let newAtlas = GlyphAtlas(device: device,
                                     fontName: newName.isEmpty ? nil : newName,
                                     pointSize: pointSize,
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
        guard let grid = grid else { return }

        // Battery saver: when neither the grid, renderer state, nor the
        // (quantised) blink phase has changed, skip the GPU encode entirely.
        // The previously presented drawable stays on screen — MTKView does
        // not require a present every vsync. Blink phase is quantised to the
        // 500 ms half-period so we wake exactly at on/off transitions.
        let now = CACurrentMediaTime()
        let blinkPhase = Int((now - blinkStart) / (CursorOverlay.blinkPeriod * 0.5))
        let gridEpoch = grid.epoch
        let mutationSeq = rendererMutationSeq
        if lastDrawnGridEpoch == gridEpoch,
           lastDrawnMutationSeq == mutationSeq,
           lastDrawnBlinkPhase == blinkPhase
        {
            return
        }

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer()
        else { return }

        lastDrawnGridEpoch = gridEpoch
        lastDrawnMutationSeq = mutationSeq
        lastDrawnBlinkPhase = blinkPhase

        let snap = grid.snapshot()
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
        // The grid normally matches the renderer's measured size, but a
        // remotely-sized grid (a peer mirror pinned to the host's geometry,
        // BUG-36) can be larger or smaller than this view. Draw the visible
        // intersection, and always index the snapshot with the GRID's cols
        // as the row stride — using the renderer's cols on a mismatched
        // buffer skews every row.
        let gridCols = Int(grid.cols)
        let gridRows = Int(grid.rows)
        let visCols = min(cols, gridCols)
        let visRows = min(rows, gridRows)
        let cellCount = visCols * visRows

        // Size the shared GPU buffers to this frame's worst case up front so
        // the build loop can write instances straight into them — staging
        // Swift arrays first costs an alloc + a second full copy per frame.
        // Per cell: ≤1 bg quad, ≤1 text glyph, ≤1 link underline.
        ensureBgCapacity(max(1, cellCount))
        ensureTextCapacity(max(1, cellCount))
        ensureCursorTextCapacity(max(1, overlay.rects.count))
        ensureCursorCapacity(max(1, cellCount + overlay.rects.count))
        guard let bgBuf = bgBuffer,
              let tBuf = textBuffer,
              let cursorTextBuf = cursorTextBuffer,
              let cBuf = cursorBuffer
        else { return }
        let bgPtr = bgBuf.contents()
            .bindMemory(to: BgInstance.self, capacity: bgCapacity)
        let textPtr = tBuf.contents()
            .bindMemory(to: TextInstance.self, capacity: textCapacity)
        let cursorTextPtr = cursorTextBuf.contents()
            .bindMemory(to: TextInstance.self, capacity: cursorTextCapacity)
        let cursorPtr = cBuf.contents()
            .bindMemory(to: CursorInstance.self, capacity: cursorCapacity)
        // Block until the previous frame's GPU read of these buffers finished
        // before writing into them. Every path past here must balance this
        // with exactly one signal (the encoder-guard bailout below, or the
        // command buffer's completion handler).
        inFlightSemaphore.wait()
        var bgCount = 0
        var textCount = 0
        var cursorTextCount = 0
        var cursorCount = 0

        let selectionSnapshot = selection   // snapshot so rendering is consistent
        let selectionColor = unpack(theme.selectionBg)

        // Build flat-index sets for search match cells before the draw loop.
        let searchMatchColor   = unpack(theme.searchMatchBg)
        let searchCurrentColor = unpack(theme.searchCurrentMatchBg)
        var currentMatchCells  = Set<Int>()
        var otherMatchCells    = Set<Int>()
        if !searchMatches.isEmpty {
            for (i, m) in searchMatches.enumerated() {
                for offset in 0..<m.length {
                    let idx = m.row * gridCols + m.colStart + offset
                    if i == currentMatchIndex {
                        currentMatchCells.insert(idx)
                    } else {
                        otherMatchCells.insert(idx)
                    }
                }
            }
        }

        if snap.count >= gridCols * gridRows {
            let atlasW = Float(atlas.atlasWidthPx)
            let atlasH = Float(atlas.atlasHeightPx)
            // ObjC class message; hoisted out of the per-cell loop.
            let cmdHeld = NSEvent.modifierFlags.contains(.command)
            for y in 0..<visRows {
                var skipUntilX = 0
                for x in 0..<visCols {
                    let c = snap[y * gridCols + x]
                    // width==0 marks the trailing half of a CJK wide glyph.
                    // We still emit a BG quad for every cell so selection
                    // highlighting is solid; only the text glyph pass skips
                    // trailing halves.
                    let pBg = themeAdaptedBlockBackground(bgColorMap[c.bg] ?? c.bg)
                    let fg = unpack(contrastAdjustedForeground(
                        fgColorMap[c.fg] ?? c.fg, on: pBg))
                    let bg = unpack(pBg)

                    // BG: render the terminal's actual background. Colored
                    // collaborator blocks are composited in the cursor pass.
                    // Priority: selection > current search match > other search matches.
                    var bi = BgInstance()
                    bi.gridPos = SIMD2<UInt16>(UInt16(x), UInt16(y))
                    let cellIdx = y * gridCols + x
                    var cellBg = bg
                    if !otherMatchCells.isEmpty, otherMatchCells.contains(cellIdx) {
                        cellBg = searchMatchColor
                    }
                    if !currentMatchCells.isEmpty, currentMatchCells.contains(cellIdx) {
                        cellBg = searchCurrentColor
                    }
                    bi.color = selectionSnapshot.map { isCellSelected(col: x, row: y, sel: $0) ? selectionColor : cellBg } ?? cellBg
                    bgPtr[bgCount] = bi
                    bgCount += 1

                    // LINK UNDERLINE: thin strip at the cell baseline for OSC 8
                    // hyperlink cells. Only visible while cmd is held, matching
                    // Ghostty's toggle-on-cmd behavior.
                    if c.url_id != 0 && cmdHeld {
                        let cellHPx = Float(atlas.cellHeightPx)
                        let ulH = max(1.0, cellHPx * 0.07)
                        var li = CursorInstance()
                        li.gridPos    = SIMD2<UInt16>(UInt16(x), UInt16(y))
                        li.originFrac = SIMD2<Float>(0, (cellHPx - ulH - 0.5) / cellHPx)
                        li.sizeFrac   = SIMD2<Float>(1, ulH / cellHPx)
                        li.color      = fg
                        cursorPtr[cursorCount] = li
                        cursorCount += 1
                    }

                    // TEXT: skip wide-glyph trailing halves, blanks, and interior
                    // cells already consumed by a ligature rendered to their left.
                    if c.width == 0 { continue }
                    if x < skipUntilX { continue }

                    // Ligature lookahead: try to match a multi-char sequence
                    // and shape it as a single glyph spanning N cells.
                    if ligaturesEnabled && TerminalRenderer.ligatureStarters.contains(c.codepoint) {
                        if let ti = makeLigatureTextInstance(
                            snap: snap, x: x, y: y, cols: gridCols,
                            atlasW: atlasW, atlasH: atlasH,
                            skipUntilX: &skipUntilX)
                        {
                            textPtr[textCount] = ti
                            textCount += 1
                            continue
                        }
                    }

                    if let ti = makeTextInstance(
                        cell: c,
                        col: UInt16(x),
                        row: UInt16(y),
                        color: fg,
                        atlasW: atlasW,
                        atlasH: atlasH)
                    {
                        textPtr[textCount] = ti
                        textCount += 1
                    }
                }
            }

            var cursorCells: [Int: CursorOverlay.Rect] = [:]
            cursorCells.reserveCapacity(overlay.rects.count)
            for block in overlay.rects {
                let index = Int(block.row) * gridCols + Int(block.col)
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
                cursorTextPtr[cursorTextCount] = ti
                cursorTextCount += 1
            }
        }

        // Full colored block cursors for all visible collaborators.
        for r in overlay.rects {
            var ci = CursorInstance()
            ci.gridPos = SIMD2<UInt16>(r.col, r.row)
            ci.originFrac = r.originFrac
            ci.sizeFrac = r.sizeFrac
            ci.color = r.color
            cursorPtr[cursorCount] = ci
            cursorCount += 1
        }

        var uniforms = RendererUniforms(
            viewportSize: SIMD2<Float>(
                Float(view.drawableSize.width),
                Float(view.drawableSize.height)),
            cellSize: SIMD2<Float>(cellW, cellH))

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            inFlightSemaphore.signal()
            return
        }

        // Pass 1: BG
        if bgCount > 0 {
            enc.setRenderPipelineState(bgPipeline)
            enc.setVertexBuffer(bgBuf, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<RendererUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: bgCount)
        }

        // Pass 2: TEXT
        if textCount > 0 {
            enc.setRenderPipelineState(textPipeline)
            enc.setVertexBuffer(tBuf, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<RendererUniforms>.stride, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: textCount)
        }

        // Pass 3: CURSOR (colored participant blocks)
        if cursorCount > 0 {
            enc.setRenderPipelineState(cursorPipeline)
            enc.setVertexBuffer(cBuf, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<RendererUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: cursorCount)
        }

        // Pass 4: redraw any glyph under a block cursor in a contrasting color
        // so fully colored cursors still leave typed text legible.
        if cursorTextCount > 0 {
            enc.setRenderPipelineState(textPipeline)
            enc.setVertexBuffer(cursorTextBuf, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<RendererUniforms>.stride, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: cursorTextCount)
        }

        enc.endEncoding()
        cmd.addCompletedHandler { [inFlightSemaphore] _ in
            inFlightSemaphore.signal()
        }
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: helpers

    func recomputeGrid(for drawableSize: CGSize) {
        let cw = max(1, atlas.cellWidthPx)
        let ch = max(1, atlas.cellHeightPx)
        let cols = max(1, Int(drawableSize.width) / cw)
        // Reserve one corner-radius worth of pixels at the bottom so the last
        // row is never clipped by macOS window rounded corners (~10 pt on
        // Sonoma/Sequoia). Full-screen has no corners so the only cost there is
        // a few pixels of background at the bottom — imperceptible at that size.
        let cornerInsetPx = Int(10.0 * atlas.scale)
        let rows = max(1, (Int(drawableSize.height) - cornerInsetPx) / ch)
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

    // MARK: theme-adaptive block backgrounds

    /// Remaps a fixed neutral block background (e.g. Claude Code's user-message
    /// bar) to a subtle theme-derived highlight when its light/dark polarity is
    /// opposite the active theme — so it stops reading as a foreign dark/light
    /// strip and instead matches the theme. Colored backgrounds (hue present),
    /// the theme's own background, and same-polarity neutrals pass through
    /// unchanged. Memoized per themed background color.
    private func themeAdaptedBlockBackground(_ bg: UInt32) -> UInt32 {
        guard adaptBlockBackgrounds else { return bg }
        if bg == theme.background { return bg }
        if let cached = blockBgAdaptCache[bg] { return cached }

        let result: UInt32
        let r = (bg >> 16) & 0xFF, g = (bg >> 8) & 0xFF, b = bg & 0xFF
        let chroma = Int(max(r, max(g, b))) - Int(min(r, min(g, b)))
        // Only touch near-neutral blocks whose polarity fights the theme.
        if chroma <= 28,
           (relativeLuminance(bg) < 0.5) != (relativeLuminance(theme.background) < 0.5)
        {
            // A subtle elevation off the theme background — toward the theme
            // foreground, so it darkens on light themes and lightens on dark
            // ones. Distinct from selectionBg to avoid looking like a selection.
            result = blend(theme.background, theme.foreground, 0.16)
        } else {
            result = bg
        }
        blockBgAdaptCache[bg] = result
        return result
    }

    // MARK: minimum-contrast floor

    /// Returns `fg` unchanged if it already meets `minimumContrastRatio`
    /// against `bg`; otherwise shifts it toward black or white (whichever the
    /// background contrasts with more), just far enough to reach the floor.
    /// Hue is preserved as much as the floor allows. Results are memoized.
    private func contrastAdjustedForeground(_ fg: UInt32, on bg: UInt32) -> UInt32 {
        guard minimumContrastRatio > 1.0 else { return fg }
        let key = (UInt64(fg) << 32) | UInt64(bg)
        if let cached = contrastAdjustCache[key] { return cached }

        let result: UInt32
        if contrastRatio(fg, bg) >= minimumContrastRatio {
            result = fg
        } else {
            // Push toward whichever endpoint the background contrasts with more.
            let target: UInt32 = relativeLuminance(bg) < 0.5 ? 0xFFFFFF : 0x000000
            if contrastRatio(target, bg) <= minimumContrastRatio {
                result = target // floor unreachable; best effort
            } else {
                var lo = 0.0, hi = 1.0
                for _ in 0..<12 {
                    let mid = (lo + hi) / 2
                    if contrastRatio(blend(fg, target, mid), bg) >= minimumContrastRatio {
                        hi = mid
                    } else {
                        lo = mid
                    }
                }
                result = blend(fg, target, hi)
            }
        }
        contrastAdjustCache[key] = result
        return result
    }

    private func blend(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func lerp(_ ca: UInt32, _ cb: UInt32) -> UInt32 {
            UInt32((Double(ca) + (Double(cb) - Double(ca)) * t).rounded())
        }
        let r = lerp((a >> 16) & 0xFF, (b >> 16) & 0xFF)
        let g = lerp((a >>  8) & 0xFF, (b >>  8) & 0xFF)
        let bl = lerp( a        & 0xFF,  b        & 0xFF)
        return (r << 16) | (g << 8) | bl
    }

    private func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func relativeLuminance(of component: UInt32) -> Double {
        let n = Double(component) / 255.0
        return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4)
    }

    private func relativeLuminance(_ packed: UInt32) -> Double {
        0.2126 * relativeLuminance(of: (packed >> 16) & 0xFF)
            + 0.7152 * relativeLuminance(of: (packed >> 8) & 0xFF)
            + 0.0722 * relativeLuminance(of: packed & 0xFF)
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

    private func makeLigatureTextInstance(
        snap: UnsafeBufferPointer<ct_cell>,
        x: Int, y: Int, cols: Int,
        atlasW: Float, atlasH: Float,
        skipUntilX: inout Int
    ) -> TextInstance? {
        let startCell = snap[y * cols + x]
        guard let candidates =
            TerminalRenderer.ligaturesByFirstScalar[startCell.codepoint]
        else { return nil }
        for (seq, scalars) in candidates {
            guard x + scalars.count <= cols else { continue }
            var ok = true
            for i in 1..<scalars.count {
                let cell = snap[y * cols + x + i]
                if cell.codepoint != scalars[i] || cell.width == 0
                    || cell.fg != startCell.fg || cell.attrs != startCell.attrs {
                    ok = false; break
                }
            }
            guard ok else { continue }
            guard let entry = atlas.entry(forSequence: seq),
                  entry.pixelW > 0, entry.pixelH > 0 else { continue }

            let fg = unpack(contrastAdjustedForeground(
                fgColorMap[startCell.fg] ?? startCell.fg,
                on: themeAdaptedBlockBackground(bgColorMap[startCell.bg] ?? startCell.bg)))
            var ti = TextInstance()
            ti.gridPos   = SIMD2<UInt16>(UInt16(x), UInt16(y))
            ti.offset    = SIMD2<Int16>(Int16(entry.bearingX),
                                        Int16(atlas.cellHeightPx - entry.bearingYTop))
            ti.glyphSize = SIMD2<UInt16>(UInt16(entry.pixelW), UInt16(entry.pixelH))
            ti.uvOrigin  = SIMD2<Float>(Float(entry.atlasX) / atlasW,
                                        Float(entry.atlasY) / atlasH)
            ti.uvSize    = SIMD2<Float>(Float(entry.pixelW) / atlasW,
                                        Float(entry.pixelH) / atlasH)
            ti.fg = fg
            skipUntilX = x + scalars.count
            return ti
        }
        return nil
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
