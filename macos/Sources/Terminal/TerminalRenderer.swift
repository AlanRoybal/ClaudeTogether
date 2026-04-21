import AppKit
import Metal
import MetalKit
import simd

/// Matches `BgInstance` in Shaders.metal. 2 + 4 = 8 bytes, round to 16.
struct BgInstance {
    var gridPos: SIMD2<UInt16> = .zero
    var color: SIMD4<UInt8> = .zero
    var _pad: (UInt16, UInt16, UInt16, UInt16, UInt16) = (0, 0, 0, 0, 0)
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
    private let sampler: MTLSamplerState

    private var bgBuffer: MTLBuffer?
    private var bgCapacity: Int = 0
    private var textBuffer: MTLBuffer?
    private var textCapacity: Int = 0

    weak var view: MTKView?
    var term: TermCore?

    private(set) var cols: UInt16 = 80
    private(set) var rows: UInt16 = 24

    var onResize: ((UInt16, UInt16) -> Void)?

    var cursorVisible = true
    private var blinkStart = CACurrentMediaTime()
    private let blinkPeriod = 1.0

    init?(view: MTKView) {
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
        guard let atlas = GlyphAtlas(device: device, pointSize: 13, scale: scale) else {
            return nil
        }
        self.atlas = atlas

        guard let library = device.makeDefaultLibrary(),
              let bgV = library.makeFunction(name: "bg_vertex"),
              let bgF = library.makeFunction(name: "bg_fragment"),
              let tV  = library.makeFunction(name: "text_vertex"),
              let tF  = library.makeFunction(name: "text_fragment")
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
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // If the actual backing scale differs from what the atlas was
        // built with (e.g. moved to a different screen), rebuild.
        if view.bounds.width > 0 {
            let actual = size.width / view.bounds.width
            if abs(actual - atlas.scale) > 0.1,
               let newAtlas = GlyphAtlas(device: device, pointSize: 13, scale: actual)
            {
                self.atlas = newAtlas
            }
        }
        recomputeGrid(for: size)
    }

    func draw(in view: MTKView) {
        guard let term = term,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer()
        else { return }

        let snap = term.snapshot()
        let (cx, cy) = term.cursor()
        let now = CACurrentMediaTime()
        let blinkOn = fmod(now - blinkStart, blinkPeriod) < blinkPeriod * 0.5
        let drawCursor = cursorVisible && blinkOn

        let cellW = Float(atlas.cellWidthPx)
        let cellH = Float(atlas.cellHeightPx)
        let cols = Int(self.cols)
        let rows = Int(self.rows)
        let cellCount = cols * rows

        var bgInstances: [BgInstance] = []
        var textInstances: [TextInstance] = []
        bgInstances.reserveCapacity(cellCount)
        textInstances.reserveCapacity(cellCount)

        if snap.count >= cellCount {
            let atlasW = Float(atlas.atlasWidthPx)
            let atlasH = Float(atlas.atlasHeightPx)
            for y in 0..<rows {
                for x in 0..<cols {
                    let c = snap[y * cols + x]
                    if c.width == 0 { continue } // trailing half of wide glyph
                    let isCursor = drawCursor && x == Int(cx) && y == Int(cy)
                    let fg = unpack(c.fg)
                    let bg = unpack(c.bg)

                    // BG: always render, swap on cursor.
                    var bi = BgInstance()
                    bi.gridPos = SIMD2<UInt16>(UInt16(x), UInt16(y))
                    bi.color = isCursor ? fg : bg
                    bgInstances.append(bi)

                    // TEXT: skip blanks.
                    let cp = c.codepoint
                    if cp == 0 || cp == 0x20 { continue }
                    let cw = Int(max(c.width, 1))
                    guard let entry = atlas.entry(for: cp, cellsWide: cw),
                          entry.pixelW > 0, entry.pixelH > 0
                    else { continue }

                    var ti = TextInstance()
                    ti.gridPos = SIMD2<UInt16>(UInt16(x), UInt16(y))
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
                    ti.fg = isCursor ? bg : fg
                    textInstances.append(ti)
                }
            }
        }

        ensureBgCapacity(bgInstances.count)
        ensureTextCapacity(textInstances.count)
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

    /// 0xRRGGBB (u32) → RGBA uchar4 (alpha = 255).
    private func unpack(_ packed: UInt32) -> SIMD4<UInt8> {
        return SIMD4<UInt8>(
            UInt8((packed >> 16) & 0xFF),
            UInt8((packed >>  8) & 0xFF),
            UInt8( packed        & 0xFF),
            255)
    }
}
