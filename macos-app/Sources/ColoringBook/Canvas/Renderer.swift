import Foundation
import Metal
import MetalKit
import simd

// Keep struct layouts in lockstep with Shaders.swift.
// All are 16-byte aligned; pads are explicit.

private struct BrushUniform {
    var center: SIMD2<Float>
    var canvasSize: SIMD2<Float>
    var color: SIMD4<Float>
    var radius: Float
    var opacity: Float
    var seed: Float
    var _pad: Float
}

private struct CompositeUniform {
    var size: SIMD2<Float>
    var time: Float
    var zoom: Float
    var pan: SIMD2<Float>
    var _pad: SIMD2<Float>
}

private struct CursorUniform {
    var center: SIMD2<Float>
    var viewSize: SIMD2<Float>
    var color: SIMD4<Float>
    var radius: Float
    var ringWidth: Float
    var filled: Float
    var _pad: Float
}

/// Cursor visualization data, held by the renderer.
/// Positions are normalized 0..1 in canvas space.
struct CursorViz {
    var pos: SIMD2<Float>
    var color: SIMD4<Float>
    var isDrawing: Bool
}

private struct PendingStamp {
    var tool: Tool
    var center: SIMD2<Float>   // canvas pixels
    var color: SIMD4<Float>
    var radius: Float          // canvas pixels
    var opacity: Float
    var seed: Float
}

private struct ActiveStroke {
    var lastPoint: SIMD2<Float>  // canvas pixels
    var color: SIMD4<Float>
    var radius: Float            // canvas pixels
    var tool: Tool
}

final class Renderer: NSObject, MTKViewDelegate {
    // Fixed logical canvas resolution. Strokes stamp here; we stretch to fit view.
    static let canvasPixels: Float = 2048

    let device: MTLDevice
    private let queue: MTLCommandQueue

    // Pipelines
    private let brushPipelines: [Tool: MTLRenderPipelineState]
    private let compositePipeline: MTLRenderPipelineState
    private let cursorPipeline: MTLRenderPipelineState

    // Offscreen canvas texture (accumulates all strokes)
    private var canvasTexture: MTLTexture

    // Line-art overlay (transparent PNG with black strokes). Always bound; a
    // 1×1 transparent texture is used when there's no page.
    private var lineArtTexture: MTLTexture
    private let transparentDefault: MTLTexture

    private var activeStrokes: [String: ActiveStroke] = [:]
    private var pendingStamps: [PendingStamp] = []

    var selfCursor: CursorViz?
    var peerCursors: [String: CursorViz] = [:]

    /// Display-only zoom (local per-user). 1.0 = fit canvas to view.
    var zoom: Float = 1.0
    /// Canvas-normalized pan offset (local per-user). 0,0 = centred.
    var pan: SIMD2<Float> = .zero

    private var drawableSize: CGSize = .zero
    private var time: Float = 0

    init(device: MTLDevice) {
        self.device = device
        guard let q = device.makeCommandQueue() else {
            fatalError("Could not create Metal command queue")
        }
        self.queue = q

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            fatalError("Metal shader compile failed: \(error)")
        }

        func makePipe(
            vertex: String,
            fragment: String,
            pixelFormat: MTLPixelFormat,
            blended: Bool
        ) -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = pixelFormat
            if blended {
                let c = desc.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .add
                c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do {
                return try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                fatalError("Pipeline build failed: \(error)")
            }
        }

        var pipes: [Tool: MTLRenderPipelineState] = [:]
        for tool in Tool.allCases {
            pipes[tool] = makePipe(
                vertex: "brush_vertex",
                fragment: tool.shaderFragmentName,
                pixelFormat: .rgba8Unorm,
                blended: true
            )
        }
        self.brushPipelines = pipes
        self.compositePipeline = makePipe(
            vertex: "fullscreen_vertex",
            fragment: "composite_fragment",
            pixelFormat: .bgra8Unorm,
            blended: false
        )
        self.cursorPipeline = makePipe(
            vertex: "cursor_vertex",
            fragment: "cursor_fragment",
            pixelFormat: .bgra8Unorm,
            blended: true
        )

        // Canvas texture
        let cdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Int(Renderer.canvasPixels),
            height: Int(Renderer.canvasPixels),
            mipmapped: false
        )
        cdesc.usage = [.renderTarget, .shaderRead]
        cdesc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: cdesc) else {
            fatalError("Could not create canvas texture")
        }
        self.canvasTexture = tex

        // 1×1 fully-transparent texture used as the default line-art binding.
        let tdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        tdesc.usage = [.shaderRead]
        guard let transparent = device.makeTexture(descriptor: tdesc) else {
            fatalError("Could not create default transparent texture")
        }
        var clearPixel: [UInt8] = [0, 0, 0, 0]
        transparent.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                            mipmapLevel: 0, withBytes: &clearPixel,
                            bytesPerRow: 4)
        self.transparentDefault = transparent
        self.lineArtTexture = transparent

        super.init()

        // Clear initial canvas to transparent
        clearCanvasTexture()
    }

    /// Set (or clear) the page's line-art texture. Pass nil for blank paper.
    func setLineArt(pngData: Data?) {
        guard let data = pngData else {
            lineArtTexture = transparentDefault
            return
        }
        let loader = MTKTextureLoader(device: device)
        do {
            let texture = try loader.newTexture(data: data, options: [
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
                .SRGB: false,
            ])
            lineArtTexture = texture
        } catch {
            NSLog("Failed to decode line art PNG: \(error)")
            lineArtTexture = transparentDefault
        }
    }

    // MARK: Public API (all called on the main thread)

    func clear() {
        activeStrokes.removeAll()
        pendingStamps.removeAll()
        clearCanvasTexture()
    }

    func beginStroke(
        id: String,
        normalizedPoint p: CGPoint,
        color: SIMD4<Float>,
        brushSize: CGFloat,
        tool: Tool
    ) {
        let center = normalizedToCanvas(p)
        // slider-units → canvas-pixel radius. 1.5× so slider=1 gives ~1.5 canvas
        // pixels (thin pencil point on a retina display).
        let radius = Float(brushSize) * 1.5
        activeStrokes[id] = ActiveStroke(
            lastPoint: center,
            color: color,
            radius: radius,
            tool: tool
        )
        enqueueStamp(tool: tool, center: center, color: color, radius: radius)
    }

    func appendPoint(id: String, normalizedPoint p: CGPoint) {
        guard var active = activeStrokes[id] else { return }
        let target = normalizedToCanvas(p)
        emitSegment(from: active.lastPoint, to: target,
                    color: active.color, radius: active.radius,
                    tool: active.tool)
        active.lastPoint = target
        activeStrokes[id] = active
    }

    func endStroke(id: String) {
        activeStrokes.removeValue(forKey: id)
    }

    // MARK: Helpers

    private func normalizedToCanvas(_ p: CGPoint) -> SIMD2<Float> {
        SIMD2<Float>(Float(p.x) * Renderer.canvasPixels,
                     Float(p.y) * Renderer.canvasPixels)
    }

    private func enqueueStamp(tool: Tool, center: SIMD2<Float>,
                              color: SIMD4<Float>, radius: Float) {
        pendingStamps.append(PendingStamp(
            tool: tool, center: center, color: color, radius: radius,
            opacity: 1.0, seed: Float.random(in: 0..<1000)
        ))
    }

    private func emitSegment(
        from a: SIMD2<Float>,
        to b: SIMD2<Float>,
        color: SIMD4<Float>,
        radius: Float,
        tool: Tool
    ) {
        let delta = b - a
        let dist = simd_length(delta)
        if dist < 0.001 { return }
        // Stamp spacing depends on tool: sketchpen/marker needs dense stamping
        // (hard edge); watercolor and pastel can afford wider spacing.
        let spacingRatio: Float = {
            switch tool {
            case .sketchpen, .pencil: return 0.12
            case .crayon:              return 0.18
            case .watercolor, .pastel: return 0.22
            }
        }()
        let spacing = max(0.5, radius * spacingRatio)
        let n = max(1, Int(ceilf(dist / spacing)))
        for i in 1...n {
            let t = Float(i) / Float(n)
            let p = a + delta * t
            enqueueStamp(tool: tool, center: p, color: color, radius: radius)
        }
    }

    private func clearCanvasTexture() {
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = canvasTexture
        pd.colorAttachments[0].loadAction = .clear
        pd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pd.colorAttachments[0].storeAction = .store
        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pd) else { return }
        enc.endEncoding()
        cb.commit()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }

        if drawableSize == .zero {
            drawableSize = view.drawableSize
        }
        time += 1.0 / 60.0

        guard let cb = queue.makeCommandBuffer() else { return }

        // 1) Flush pending stamps into the canvas texture
        if !pendingStamps.isEmpty {
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = canvasTexture
            pd.colorAttachments[0].loadAction = .load
            pd.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: pd) {
                var currentTool: Tool?
                for stamp in pendingStamps {
                    if stamp.tool != currentTool {
                        if let pipe = brushPipelines[stamp.tool] {
                            enc.setRenderPipelineState(pipe)
                            currentTool = stamp.tool
                        } else {
                            continue
                        }
                    }
                    var u = BrushUniform(
                        center: stamp.center,
                        canvasSize: SIMD2<Float>(Renderer.canvasPixels, Renderer.canvasPixels),
                        color: stamp.color,
                        radius: stamp.radius,
                        opacity: stamp.opacity,
                        seed: stamp.seed,
                        _pad: 0
                    )
                    enc.setVertexBytes(&u, length: MemoryLayout<BrushUniform>.size, index: 0)
                    enc.setFragmentBytes(&u, length: MemoryLayout<BrushUniform>.size, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                }
                enc.endEncoding()
            }
            pendingStamps.removeAll(keepingCapacity: true)
        }

        // 2) Composite + cursors into the drawable
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            // Composite pass
            enc.setRenderPipelineState(compositePipeline)
            var cu = CompositeUniform(
                size: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
                time: time,
                zoom: zoom,
                pan: pan,
                _pad: .zero
            )
            enc.setFragmentBytes(&cu, length: MemoryLayout<CompositeUniform>.size, index: 0)
            enc.setFragmentTexture(canvasTexture, index: 0)
            enc.setFragmentTexture(lineArtTexture, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            // Cursor overlays
            enc.setRenderPipelineState(cursorPipeline)
            drawCursors(encoder: enc)

            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()
    }

    private func drawCursors(encoder: MTLRenderCommandEncoder) {
        let viewSize = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        // Self cursor (larger ring, fills when drawing)
        if let s = selfCursor {
            emitCursor(encoder: encoder,
                       cursor: s,
                       viewSize: viewSize,
                       radius: 14,
                       ringWidth: 2.5,
                       isSelf: true)
        }
        // Peer cursors
        for (_, p) in peerCursors {
            emitCursor(encoder: encoder,
                       cursor: p,
                       viewSize: viewSize,
                       radius: 10,
                       ringWidth: 2.0,
                       isSelf: false)
        }
    }

    private func emitCursor(
        encoder: MTLRenderCommandEncoder,
        cursor: CursorViz,
        viewSize: SIMD2<Float>,
        radius: Float,
        ringWidth: Float,
        isSelf: Bool
    ) {
        // Map canvas-normalized → view-normalized through local zoom + pan so
        // the cursor stays aligned with the strokes under it while panning /
        // pinching. Inverse of the composite shader's sampleUV transform.
        let vx = (cursor.pos.x - 0.5 - pan.x) * zoom + 0.5
        let vy = (cursor.pos.y - 0.5 - pan.y) * zoom + 0.5
        let centerPx = SIMD2<Float>(vx * viewSize.x, vy * viewSize.y)
        var u = CursorUniform(
            center: centerPx,
            viewSize: viewSize,
            color: cursor.color,
            radius: radius,
            ringWidth: ringWidth,
            filled: (isSelf && cursor.isDrawing) ? 1.0 : 0.0,
            _pad: 0
        )
        encoder.setVertexBytes(&u, length: MemoryLayout<CursorUniform>.size, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<CursorUniform>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}

/// Parse "#RRGGBB" into a Metal-friendly RGBA float4 (alpha = 1).
func parseHexColor(_ hex: String) -> SIMD4<Float> {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else {
        return SIMD4<Float>(0.5, 0.5, 0.5, 1)
    }
    let r = Float((v >> 16) & 0xFF) / 255
    let g = Float((v >> 8)  & 0xFF) / 255
    let b = Float( v        & 0xFF) / 255
    return SIMD4<Float>(r, g, b, 1)
}
