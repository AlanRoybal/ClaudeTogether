import AppKit
import Metal
import MetalKit
import simd

/// Metal renderer for the collaborative editor. It reuses the terminal
/// shader pipelines but draws from `EditorGridModel` instead of `TermCore`.
final class EditorRenderer: NSObject, MTKViewDelegate {
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
    private var selectionBuffer: MTLBuffer?
    private var selectionCapacity: Int = 0
    private var cursorBuffer: MTLBuffer?
    private var cursorCapacity: Int = 0
    private var cursorTextBuffer: MTLBuffer?
    private var cursorTextCapacity: Int = 0

    weak var view: MTKView?
    var grid: EditorGridModel?

    private(set) var cols: UInt16 = 80
    private(set) var rows: UInt16 = 24

    var onResize: ((UInt16, UInt16) -> Void)?

    private var blinkStart = CACurrentMediaTime()

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            return nil
        }
        view.device = device
        self.device = device

        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

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
              let tV = library.makeFunction(name: "text_vertex"),
              let tF = library.makeFunction(name: "text_fragment"),
              let cV = library.makeFunction(name: "cursor_vertex"),
              let cF = library.makeFunction(name: "cursor_fragment")
        else {
            return nil
        }

        let fmt = view.colorPixelFormat
        do {
            let bgDesc = MTLRenderPipelineDescriptor()
            bgDesc.vertexFunction = bgV
            bgDesc.fragmentFunction = bgF
            bgDesc.colorAttachments[0].pixelFormat = fmt
            self.bgPipeline = try device.makeRenderPipelineState(descriptor: bgDesc)

            let textDesc = MTLRenderPipelineDescriptor()
            textDesc.vertexFunction = tV
            textDesc.fragmentFunction = tF
            textDesc.colorAttachments[0].pixelFormat = fmt
            let textAttachment = textDesc.colorAttachments[0]!
            textAttachment.isBlendingEnabled = true
            textAttachment.rgbBlendOperation = .add
            textAttachment.alphaBlendOperation = .add
            textAttachment.sourceRGBBlendFactor = .sourceAlpha
            textAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            textAttachment.sourceAlphaBlendFactor = .sourceAlpha
            textAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.textPipeline = try device.makeRenderPipelineState(descriptor: textDesc)

            let cursorDesc = MTLRenderPipelineDescriptor()
            cursorDesc.vertexFunction = cV
            cursorDesc.fragmentFunction = cF
            cursorDesc.colorAttachments[0].pixelFormat = fmt
            let cursorAttachment = cursorDesc.colorAttachments[0]!
            cursorAttachment.isBlendingEnabled = true
            cursorAttachment.rgbBlendOperation = .add
            cursorAttachment.alphaBlendOperation = .add
            cursorAttachment.sourceRGBBlendFactor = .sourceAlpha
            cursorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            cursorAttachment.sourceAlphaBlendFactor = .sourceAlpha
            cursorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.cursorPipeline = try device.makeRenderPipelineState(descriptor: cursorDesc)
        } catch {
            NSLog("EditorRenderer pipeline failed: \(error)")
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
        view.clearColor = MTLClearColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if view.bounds.width > 0 {
            let actual = size.width / view.bounds.width
            if abs(actual - atlas.scale) > 0.1,
               let rebuilt = GlyphAtlas(device: device, pointSize: 13, scale: actual)
            {
                atlas = rebuilt
            }
        }
        recomputeGrid(for: size)
    }

    func draw(in view: MTKView) {
        guard let grid,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer()
        else {
            return
        }

        let cells = grid.cells
        let rows = Int(grid.rows)
        let cols = Int(grid.cols)
        let cellCount = rows * cols

        let overlay = buildCursorOverlay(from: grid.cursors, cols: cols)

        var bgInstances: [BgInstance] = []
        var selectionInstances: [CursorInstance] = []
        var textInstances: [TextInstance] = []
        var cursorInstances: [CursorInstance] = []
        var cursorTextInstances: [TextInstance] = []

        bgInstances.reserveCapacity(cellCount)
        selectionInstances.reserveCapacity(grid.selections.count)
        textInstances.reserveCapacity(cellCount)
        cursorInstances.reserveCapacity(overlay.count)
        cursorTextInstances.reserveCapacity(overlay.count)

        let atlasW = Float(atlas.atlasWidthPx)
        let atlasH = Float(atlas.atlasHeightPx)

        if cells.count >= cellCount {
            for row in 0..<rows {
                for col in 0..<cols {
                    let cell = cells[row * cols + col]
                    var bg = BgInstance()
                    bg.gridPos = SIMD2<UInt16>(UInt16(col), UInt16(row))
                    bg.color = unpack(cell.bg, alpha: 255)
                    bgInstances.append(bg)

                    if let text = makeTextInstance(
                        codepoint: cell.codepoint,
                        col: UInt16(col),
                        row: UInt16(row),
                        color: unpack(cell.fg, alpha: 255),
                        atlasW: atlasW,
                        atlasH: atlasH)
                    {
                        textInstances.append(text)
                    }
                }
            }

            for selection in grid.selections {
                var rect = CursorInstance()
                rect.gridPos = SIMD2<UInt16>(selection.startCol, selection.row)
                rect.originFrac = SIMD2<Float>(0, 0)
                rect.sizeFrac = SIMD2<Float>(
                    Float(Int(selection.endCol) - Int(selection.startCol)),
                    1.0)
                rect.color = unpack(selection.color, alpha: 64)
                selectionInstances.append(rect)
            }

            for block in overlay {
                cursorInstances.append(block.instance)
                if block.isLocal { continue }
                let index = Int(block.instance.gridPos.y) * cols + Int(block.instance.gridPos.x)
                guard index >= 0, index < cells.count else { continue }
                let cell = cells[index]
                guard let text = makeTextInstance(
                    codepoint: cell.codepoint,
                    col: block.instance.gridPos.x,
                    row: block.instance.gridPos.y,
                    color: cursorTextColor(on: block.instance.color),
                    atlasW: atlasW,
                    atlasH: atlasH)
                else {
                    continue
                }
                cursorTextInstances.append(text)
            }
        }

        ensureBgCapacity(bgInstances.count)
        ensureSelectionCapacity(selectionInstances.count)
        ensureTextCapacity(textInstances.count)
        ensureCursorCapacity(cursorInstances.count)
        ensureCursorTextCapacity(cursorTextInstances.count)

        copy(bgInstances, into: bgBuffer)
        copy(selectionInstances, into: selectionBuffer)
        copy(textInstances, into: textBuffer)
        copy(cursorInstances, into: cursorBuffer)
        copy(cursorTextInstances, into: cursorTextBuffer)

        var uniforms = RendererUniforms(
            viewportSize: SIMD2<Float>(
                Float(view.drawableSize.width),
                Float(view.drawableSize.height)),
            cellSize: SIMD2<Float>(
                Float(atlas.cellWidthPx),
                Float(atlas.cellHeightPx)))

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            return
        }

        if !bgInstances.isEmpty, let bgBuffer {
            enc.setRenderPipelineState(bgPipeline)
            enc.setVertexBuffer(bgBuffer, offset: 0, index: 0)
            enc.setVertexBytes(
                &uniforms,
                length: MemoryLayout<RendererUniforms>.stride,
                index: 1)
            enc.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: bgInstances.count)
        }

        if !selectionInstances.isEmpty, let selectionBuffer {
            enc.setRenderPipelineState(cursorPipeline)
            enc.setVertexBuffer(selectionBuffer, offset: 0, index: 0)
            enc.setVertexBytes(
                &uniforms,
                length: MemoryLayout<RendererUniforms>.stride,
                index: 1)
            enc.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: selectionInstances.count)
        }

        if !textInstances.isEmpty, let textBuffer {
            enc.setRenderPipelineState(textPipeline)
            enc.setVertexBuffer(textBuffer, offset: 0, index: 0)
            enc.setVertexBytes(
                &uniforms,
                length: MemoryLayout<RendererUniforms>.stride,
                index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: textInstances.count)
        }

        if !cursorInstances.isEmpty, let cursorBuffer {
            enc.setRenderPipelineState(cursorPipeline)
            enc.setVertexBuffer(cursorBuffer, offset: 0, index: 0)
            enc.setVertexBytes(
                &uniforms,
                length: MemoryLayout<RendererUniforms>.stride,
                index: 1)
            enc.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: cursorInstances.count)
        }

        if !cursorTextInstances.isEmpty, let cursorTextBuffer {
            enc.setRenderPipelineState(textPipeline)
            enc.setVertexBuffer(cursorTextBuffer, offset: 0, index: 0)
            enc.setVertexBytes(
                &uniforms,
                length: MemoryLayout<RendererUniforms>.stride,
                index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: cursorTextInstances.count)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

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

    private struct CursorDraw {
        var instance: CursorInstance
        var isLocal: Bool
    }

    private func buildCursorOverlay(from cursors: [UserCursor],
                                    cols: Int) -> [CursorDraw]
    {
        struct CellKey: Hashable {
            var col: UInt16
            var row: UInt16
        }

        let phase = fmod(CACurrentMediaTime() - blinkStart, CursorOverlay.blinkPeriod)
        let blinkOn = phase < CursorOverlay.blinkPeriod * 0.5

        var next: [CursorDraw] = []
        var lanes: [CellKey: Int] = [:]

        for cursor in cursors {
            if cursor.isLocal && !blinkOn { continue }

            var instance = CursorInstance()
            instance.gridPos = SIMD2<UInt16>(cursor.col, cursor.row)
            if cursor.isLocal {
                instance.originFrac = SIMD2<Float>(0.06, 0.08)
                instance.sizeFrac = SIMD2<Float>(0.10, 0.84)
                instance.color = unpack(cursor.color, alpha: 235)
                next.append(CursorDraw(instance: instance, isLocal: true))
                continue
            }

            let key = CellKey(col: cursor.col, row: cursor.row)
            let lane = lanes[key, default: 0]
            lanes[key] = lane + 1
            let inset = min(Float(lane) * 0.12, 0.30)
            instance.originFrac = SIMD2<Float>(repeating: inset)
            instance.sizeFrac = SIMD2<Float>(repeating: max(0.0, 1.0 - inset * 2.0))
            instance.color = unpack(cursor.color, alpha: 235)
            next.append(CursorDraw(instance: instance, isLocal: false))
        }

        return next
    }

    private func ensureBgCapacity(_ n: Int) {
        if n <= bgCapacity { return }
        let cap = max(n, 1024)
        bgBuffer = device.makeBuffer(
            length: cap * MemoryLayout<BgInstance>.stride,
            options: [.storageModeShared])
        bgCapacity = cap
    }

    private func ensureSelectionCapacity(_ n: Int) {
        if n <= selectionCapacity { return }
        let cap = max(n, 64)
        selectionBuffer = device.makeBuffer(
            length: cap * MemoryLayout<CursorInstance>.stride,
            options: [.storageModeShared])
        selectionCapacity = cap
    }

    private func ensureTextCapacity(_ n: Int) {
        if n <= textCapacity { return }
        let cap = max(n, 1024)
        textBuffer = device.makeBuffer(
            length: cap * MemoryLayout<TextInstance>.stride,
            options: [.storageModeShared])
        textCapacity = cap
    }

    private func ensureCursorCapacity(_ n: Int) {
        if n <= cursorCapacity { return }
        let cap = max(n, 32)
        cursorBuffer = device.makeBuffer(
            length: cap * MemoryLayout<CursorInstance>.stride,
            options: [.storageModeShared])
        cursorCapacity = cap
    }

    private func ensureCursorTextCapacity(_ n: Int) {
        if n <= cursorTextCapacity { return }
        let cap = max(n, 32)
        cursorTextBuffer = device.makeBuffer(
            length: cap * MemoryLayout<TextInstance>.stride,
            options: [.storageModeShared])
        cursorTextCapacity = cap
    }

    private func copy<T>(_ values: [T], into buffer: MTLBuffer?) {
        guard !values.isEmpty, let buffer else { return }
        values.withUnsafeBytes { raw in
            _ = memcpy(buffer.contents(), raw.baseAddress!, raw.count)
        }
    }

    private func unpack(_ packed: UInt32, alpha: UInt8) -> SIMD4<UInt8> {
        SIMD4<UInt8>(
            UInt8((packed >> 16) & 0xFF),
            UInt8((packed >> 8) & 0xFF),
            UInt8(packed & 0xFF),
            alpha)
    }

    private func makeTextInstance(codepoint: UInt32,
                                  col: UInt16,
                                  row: UInt16,
                                  color: SIMD4<UInt8>,
                                  atlasW: Float,
                                  atlasH: Float) -> TextInstance?
    {
        guard codepoint != 0, codepoint != 0x20 else { return nil }
        guard let entry = atlas.entry(for: codepoint, cellsWide: 1),
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
