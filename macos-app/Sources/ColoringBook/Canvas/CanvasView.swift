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

        // Whenever the active page changes, swap the line-art texture to match.
        // We watch both `pages` (so newly added pages get picked up) and
        // `activePageId` (so switching pages updates the texture immediately).
        Publishers.CombineLatest(session.$pages, session.$activePageId)
            .sink { [weak self] pages, activeId in
                let active = pages.first { $0.pageId == activeId }
                self?.renderer?.setLineArt(pngData: active?.imageData)
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
        case .roomState(let activePageId, let strokes):
            // Stamp only the strokes that belong to the active page.
            renderer.clear()
            let active = strokes.filter { $0.pageId == activePageId }
            for s in active { stampStroke(s, renderer: renderer) }

        case .peerStrokeStart(_, let h, let pageId, let fp):
            // Ignore strokes for non-active pages (still recorded server-side
            // and on this client's strokesByPage; only the visible page draws).
            guard pageId == session?.activePageId else {
                cachePeerStrokeForLater(header: h, pageId: pageId, firstPoint: fp)
                return
            }
            let color = SIMD4<Float>(
                Float(h.color.r), Float(h.color.g), Float(h.color.b), Float(h.color.a))
            renderer.beginStroke(
                id: h.id,
                normalizedPoint: CGPoint(x: fp.x, y: fp.y),
                color: color,
                brushSize: CGFloat(h.brushSize),
                tool: h.tool
            )
            // Track in-flight peer strokes per page so we can re-stamp after
            // a page-switch if needed.
            inFlightPeerStrokes[h.id] = InFlightStroke(
                pageId: pageId, header: h, points: [fp]
            )

        case .peerStrokePoint(_, let strokeId, let p):
            if var entry = inFlightPeerStrokes[strokeId] {
                entry.points.append(p)
                inFlightPeerStrokes[strokeId] = entry
                if entry.pageId == session?.activePageId {
                    renderer.appendPoint(
                        id: strokeId, normalizedPoint: CGPoint(x: p.x, y: p.y)
                    )
                }
            }

        case .peerStrokeEnd(_, let strokeId):
            if let entry = inFlightPeerStrokes.removeValue(forKey: strokeId),
               let session = session {
                let stroke = Stroke(
                    id: entry.header.id,
                    userId: entry.header.userId,
                    tool: entry.header.tool,
                    color: entry.header.color,
                    brushSize: entry.header.brushSize,
                    points: entry.points,
                    complete: true,
                    pageId: entry.pageId
                )
                session._recordLocalStroke(stroke)
                if entry.pageId == session.activePageId {
                    renderer.endStroke(id: strokeId)
                }
            } else {
                renderer.endStroke(id: strokeId)
            }

        case .activePageChanged:
            // Wipe the canvas texture and re-stamp the new active page's
            // strokes from the session's per-page index.
            renderer.clear()
            if let session = session {
                for s in session.strokesForActivePage() {
                    stampStroke(s, renderer: renderer)
                }
            }

        case .activePageStrokesCleared(let pageId):
            if pageId == session?.activePageId {
                renderer.clear()
            }
        }
    }

    private func stampStroke(_ s: Stroke, renderer: Renderer) {
        guard let first = s.points.first else { return }
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
            renderer.appendPoint(id: s.id, normalizedPoint: CGPoint(x: p.x, y: p.y))
        }
        if s.complete { renderer.endStroke(id: s.id) }
    }

    private struct InFlightStroke {
        let pageId: String
        let header: StrokeHeader
        var points: [StrokePoint]
    }
    private var inFlightPeerStrokes: [String: InFlightStroke] = [:]

    private func cachePeerStrokeForLater(
        header: StrokeHeader, pageId: String, firstPoint: StrokePoint
    ) {
        inFlightPeerStrokes[header.id] = InFlightStroke(
            pageId: pageId, header: header, points: [firstPoint]
        )
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
              !session.currentUserId.isEmpty,
              let pageId = session.activePageId else { return }
        let strokeId = UUID().uuidString
        currentStrokeId = strokeId
        currentLocalStrokePageId = pageId
        let wireColor = WireColor(r: session.color.r, g: session.color.g,
                                  b: session.color.b, a: 1)
        currentLocalStrokeHeader = StrokeHeader(
            id: strokeId,
            userId: session.currentUserId,
            tool: session.tool,
            color: wireColor,
            brushSize: Double(session.brushSize)
        )
        currentLocalStrokePoints = []
        let simdColor = SIMD4<Float>(
            Float(session.color.r), Float(session.color.g), Float(session.color.b), 1)
        renderer.beginStroke(
            id: strokeId,
            normalizedPoint: pos,
            color: simdColor,
            brushSize: session.brushSize,
            tool: session.tool
        )
        let firstPoint = StrokePoint(
            x: Double(pos.x), y: Double(pos.y),
            pressure: 1.0, t: Date().timeIntervalSince1970
        )
        currentLocalStrokePoints.append(firstPoint)
        let payload = StrokeStartPayload(
            id: strokeId,
            userId: session.currentUserId,
            tool: session.tool,
            color: wireColor,
            brushSize: Double(session.brushSize),
            pageId: pageId,
            point: firstPoint
        )
        session.network.send(.strokeStart(payload))
    }

    func gestureDidAppendPoint(_ pos: CGPoint) {
        guard let renderer = renderer, let session = session,
              let id = currentStrokeId else { return }
        renderer.appendPoint(id: id, normalizedPoint: pos)
        let point = StrokePoint(x: Double(pos.x), y: Double(pos.y),
                                pressure: 1.0, t: Date().timeIntervalSince1970)
        currentLocalStrokePoints.append(point)
        session.network.send(.strokePoint(strokeId: id, point: point))
    }

    func gestureDidEndStroke() {
        guard let renderer = renderer, let session = session,
              let id = currentStrokeId,
              let header = currentLocalStrokeHeader,
              let pageId = currentLocalStrokePageId else { return }
        renderer.endStroke(id: id)
        let stroke = Stroke(
            id: header.id,
            userId: header.userId,
            tool: header.tool,
            color: header.color,
            brushSize: header.brushSize,
            points: currentLocalStrokePoints,
            complete: true,
            pageId: pageId
        )
        session._recordLocalStroke(stroke)
        session.network.send(.strokeEnd(strokeId: id))
        currentStrokeId = nil
        currentLocalStrokeHeader = nil
        currentLocalStrokePageId = nil
        currentLocalStrokePoints = []
    }

    private var currentLocalStrokeHeader: StrokeHeader?
    private var currentLocalStrokePageId: String?
    private var currentLocalStrokePoints: [StrokePoint] = []
}
