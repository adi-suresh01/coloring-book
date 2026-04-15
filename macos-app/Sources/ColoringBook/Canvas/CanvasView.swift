import SwiftUI
import MetalKit
import Combine
import simd

struct CanvasView: NSViewRepresentable {
    @EnvironmentObject var session: SessionModel

    func makeCoordinator() -> CanvasCoordinator {
        CanvasCoordinator()
    }

    func makeNSView(context: Context) -> CanvasMTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this device")
        }
        let view = CanvasMTKView(frame: .zero, device: device)
        let renderer = Renderer(device: device)
        view.delegate = renderer
        view.gestureMachine.delegate = context.coordinator

        context.coordinator.bind(view: view, renderer: renderer, session: session)
        return view
    }

    func updateNSView(_ view: CanvasMTKView, context: Context) {
        context.coordinator.session = session
    }
}

@MainActor
final class CanvasCoordinator: NSObject, GestureDelegate {
    var session: SessionModel?
    private weak var view: CanvasMTKView?
    private var renderer: Renderer?

    private var currentStrokeId: String?
    private var cancellables = Set<AnyCancellable>()

    // Throttle cursor broadcasts to ~60 Hz
    private var lastCursorBroadcast: TimeInterval = 0

    func bind(view: CanvasMTKView, renderer: Renderer, session: SessionModel) {
        self.view = view
        self.renderer = renderer
        self.session = session

        view.onToggleCanvasMode = { [weak session] in
            session?.toggleCanvasMode()
        }
        view.onPinchMagnification = { [weak session] delta, anchor in
            session?.applyPinchFactor(1 + delta, anchorViewUV: anchor)
        }
        view.onResetZoom = { [weak session] in
            session?.resetZoom()
        }
        // 2-finger trackpad drag (and the ensuing momentum tail) sends scroll
        // events; turn those into pan deltas in canvas-normalized units.
        view.onScrollPan = { [weak session] dxView, dyView in
            guard let session = session else { return }
            // Map view-fraction → canvas-fraction by /zoom. The negative sign
            // makes the gesture feel like grabbing the paper: drag fingers
            // right → page slides right under fingers → reveal what was to
            // the LEFT (matches natural-scroll / Maps convention).
            let z = max(session.zoom, 0.0001)
            session.applyPanDelta(dx: -dxView / z, dy: -dyView / z)
        }

        session.$zoom
            .sink { [weak self] z in
                self?.renderer?.zoom = Float(z)
                self?.view?.gestureMachine.sensitivity = 1.0 / z
            }
            .store(in: &cancellables)

        session.$pan
            .sink { [weak self] p in
                self?.renderer?.pan = SIMD2<Float>(Float(p.width), Float(p.height))
            }
            .store(in: &cancellables)

        // Apply whatever page is currently set (e.g., from room_state on join
        // or a later set_page broadcast).
        session.$currentPage
            .sink { [weak self] page in
                self?.renderer?.setLineArt(pngData: page?.imageData)
            }
            .store(in: &cancellables)

        session.canvasEvents
            .sink { [weak self] event in
                self?.handleCanvasEvent(event)
            }
            .store(in: &cancellables)

        session.$peerCursors
            .sink { [weak self] cursors in
                self?.syncPeerCursors(cursors)
            }
            .store(in: &cancellables)

        session.$isInCanvasMode
            .sink { [weak self] on in
                self?.applyCanvasMode(on)
            }
            .store(in: &cancellables)

        // Prime the view with the current mode (important when the view is
        // created after the session has already been initialized).
        view.isInCanvasMode = session.isInCanvasMode
        applyCanvasMode(session.isInCanvasMode)
    }

    private func applyCanvasMode(_ on: Bool) {
        view?.isInCanvasMode = on
        if !on {
            renderer?.selfCursor = nil
        } else if let view = view, let session = session {
            let c = view.gestureMachine.cursor
            let color = SIMD4<Float>(
                Float(session.color.r),
                Float(session.color.g),
                Float(session.color.b),
                1
            )
            renderer?.selfCursor = CursorViz(
                pos: SIMD2<Float>(Float(c.x), Float(c.y)),
                color: color,
                isDrawing: false
            )
        }
    }

    private func syncPeerCursors(_ cursors: [String: PeerCursor]) {
        guard let renderer = renderer else { return }
        var next: [String: CursorViz] = [:]
        for (uid, c) in cursors {
            next[uid] = CursorViz(
                pos: SIMD2<Float>(Float(c.x), Float(c.y)),
                color: parseHexColor(c.colorHex),
                isDrawing: false
            )
        }
        renderer.peerCursors = next
    }

    private func handleCanvasEvent(_ event: CanvasEvent) {
        guard let renderer = renderer else { return }
        switch event {
        case .roomState(let strokes):
            renderer.clear()
            for s in strokes {
                guard let first = s.points.first else { continue }
                let color = SIMD4<Float>(
                    Float(s.color.r), Float(s.color.g), Float(s.color.b), Float(s.color.a))
                renderer.beginStroke(
                    id: s.id,
                    normalizedPoint: CGPoint(x: first.x, y: first.y),
                    color: color,
                    brushSize: CGFloat(s.brushSize),
                    tool: s.tool
                )
                for p in s.points.dropFirst() {
                    renderer.appendPoint(
                        id: s.id,
                        normalizedPoint: CGPoint(x: p.x, y: p.y)
                    )
                }
                if s.complete { renderer.endStroke(id: s.id) }
            }
        case .peerStrokeStart(_, let h, let fp):
            let color = SIMD4<Float>(
                Float(h.color.r), Float(h.color.g), Float(h.color.b), Float(h.color.a))
            renderer.beginStroke(
                id: h.id,
                normalizedPoint: CGPoint(x: fp.x, y: fp.y),
                color: color,
                brushSize: CGFloat(h.brushSize),
                tool: h.tool
            )
        case .peerStrokePoint(_, let strokeId, let p):
            renderer.appendPoint(
                id: strokeId,
                normalizedPoint: CGPoint(x: p.x, y: p.y)
            )
        case .peerStrokeEnd(_, let strokeId):
            renderer.endStroke(id: strokeId)
        case .pageChanged(let page):
            renderer.setLineArt(pngData: page.flatMap { p in
                p.imageBase64.isEmpty ? nil : Data(base64Encoded: p.imageBase64)
            })
        case .canvasCleared:
            renderer.clear()
            // Re-apply current line-art page after clear (clear wipes the canvas
            // texture; line art is a separate texture but we keep it explicit).
            if let data = session?.currentPage?.imageData {
                renderer.setLineArt(pngData: data)
            }
        }
    }

    // MARK: GestureDelegate

    func gestureDidUpdateCursor(_ pos: CGPoint, isDrawing: Bool) {
        guard let renderer = renderer, let session = session,
              session.isInCanvasMode else { return }
        let color = SIMD4<Float>(
            Float(session.color.r),
            Float(session.color.g),
            Float(session.color.b),
            1
        )
        renderer.selfCursor = CursorViz(
            pos: SIMD2<Float>(Float(pos.x), Float(pos.y)),
            color: color,
            isDrawing: isDrawing
        )
        let now = Date().timeIntervalSince1970
        if now - lastCursorBroadcast > 0.016 {
            lastCursorBroadcast = now
            session.network.send(.cursor(x: Double(pos.x), y: Double(pos.y)))
        }
    }

    func gestureDidStartStroke(at pos: CGPoint) {
        guard let renderer = renderer, let session = session,
              !session.currentUserId.isEmpty else { return }
        let strokeId = UUID().uuidString
        currentStrokeId = strokeId
        let wireColor = WireColor(r: session.color.r, g: session.color.g,
                                  b: session.color.b, a: 1)
        let simdColor = SIMD4<Float>(
            Float(session.color.r), Float(session.color.g), Float(session.color.b), 1)
        renderer.beginStroke(
            id: strokeId,
            normalizedPoint: pos,
            color: simdColor,
            brushSize: session.brushSize,
            tool: session.tool
        )
        let payload = StrokeStartPayload(
            id: strokeId,
            userId: session.currentUserId,
            tool: session.tool,
            color: wireColor,
            brushSize: Double(session.brushSize),
            point: StrokePoint(x: Double(pos.x), y: Double(pos.y),
                               pressure: 1.0, t: Date().timeIntervalSince1970)
        )
        session.network.send(.strokeStart(payload))
    }

    func gestureDidAppendPoint(_ pos: CGPoint) {
        guard let renderer = renderer, let session = session,
              let id = currentStrokeId else { return }
        renderer.appendPoint(id: id, normalizedPoint: pos)
        let point = StrokePoint(x: Double(pos.x), y: Double(pos.y),
                                pressure: 1.0, t: Date().timeIntervalSince1970)
        session.network.send(.strokePoint(strokeId: id, point: point))
    }

    func gestureDidEndStroke() {
        guard let renderer = renderer, let session = session,
              let id = currentStrokeId else { return }
        renderer.endStroke(id: id)
        session.network.send(.strokeEnd(strokeId: id))
        currentStrokeId = nil
    }

}
