import Foundation
import SwiftUI
import Combine

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

struct PeerCursor: Equatable {
    let userId: String
    let x: Double
    let y: Double
    let colorHex: String
}

enum CanvasEvent {
    case roomState(strokes: [Stroke])
    case peerStrokeStart(userId: String, header: StrokeHeader, firstPoint: StrokePoint)
    case peerStrokePoint(userId: String, strokeId: String, point: StrokePoint)
    case peerStrokeEnd(userId: String, strokeId: String)
    case pageChanged(page: WirePage?)
    case canvasCleared
}

struct CurrentPage: Equatable {
    let pageId: String
    let displayName: String
    let imageData: Data?   // nil = blank paper
}

@MainActor
final class SessionModel: ObservableObject {
    // MARK: Drawing state (UI-facing)
    @Published var tool: Tool = .sketchpen
    @Published var color: ArtColor = ArtColor.palette[2]     // cherry-red
    @Published var brushSize: CGFloat = Tool.sketchpen.defaultBrushSize

    @Published var isInCanvasMode: Bool = false
    func toggleCanvasMode() { isInCanvasMode.toggle() }

    // MARK: Current page (synced with room — broadcasts to peers on change)
    @Published var currentPage: CurrentPage? = nil

    func setPage(_ page: CurrentPage?) {
        currentPage = page
        let wire: WirePage? = page.map { p in
            WirePage(
                pageId: p.pageId,
                displayName: p.displayName,
                mimeType: "image/png",
                imageBase64: p.imageData?.base64EncodedString() ?? ""
            )
        }
        network.send(.setPage(wire))
    }

    func clearCanvas() {
        canvasEvents.send(.canvasCleared)
        network.send(.clearCanvas)
    }

    // MARK: View zoom + pan (local only)
    @Published var zoom: CGFloat = 1.0
    @Published var pan: CGSize = .zero
    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 6.0

    /// Multiply current zoom by `factor`, anchored at `anchorViewUV` (canvas-
    /// view UV, y-down). The pan is adjusted so the anchor stays under the
    /// pinch point — the Maps / Photos pinch-to-zoom behavior. Without this
    /// the canvas always scales around the centre, which feels disconnected
    /// when you're trying to zoom into a corner.
    func applyPinchFactor(
        _ factor: CGFloat,
        anchorViewUV: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) {
        let oldZoom = zoom
        let newZoom = min(Self.maxZoom, max(Self.minZoom, oldZoom * factor))
        if oldZoom != newZoom {
            // newPan = oldPan + (anchor − 0.5) · (1/oldZoom − 1/newZoom)
            // Derived from holding the anchor's canvasUV constant across the
            // zoom step.
            let dx = (anchorViewUV.x - 0.5) * (1 / oldZoom - 1 / newZoom)
            let dy = (anchorViewUV.y - 0.5) * (1 / oldZoom - 1 / newZoom)
            pan = CGSize(width: pan.width + dx, height: pan.height + dy)
        }
        zoom = newZoom
        clampPan()
    }

    /// Add a 3-finger-drag delta (canvas-normalized) to the pan offset. The
    /// clamp keeps us from scrolling off the canvas entirely.
    func applyPanDelta(dx: CGFloat, dy: CGFloat) {
        pan = CGSize(width: pan.width + dx, height: pan.height + dy)
        clampPan()
    }

    func resetZoom() {
        zoom = 1.0
        pan = .zero
    }

    /// At zoom Z the visible portion is 1/Z of the canvas. Max |pan| is
    /// therefore ½·(1 − 1/Z); at Z=1 that's 0 (no point in panning).
    private func clampPan() {
        let maxOff = max(0, 0.5 * (1 - 1 / zoom))
        pan = CGSize(
            width: min(maxOff, max(-maxOff, pan.width)),
            height: min(maxOff, max(-maxOff, pan.height))
        )
    }

    // MARK: Connection state
    @Published var connectionState: ConnectionState = .disconnected
    @Published var peerCount: Int = 0
    @Published var peerCursors: [String: PeerCursor] = [:]
    @Published var peerColorById: [String: String] = [:]

    // MARK: Identity — set by `configureAuth` after login
    @Published private(set) var currentUser: AuthUser?
    private var currentToken: String?
    let userColorHex: String

    // MARK: Active room (`nil` = no room picked yet)
    @Published private(set) var roomId: String?
    @Published private(set) var roomDisplayName: String?

    /// Convenience for components that send stroke messages.
    var currentUserId: String { currentUser?.id ?? "" }

    // MARK: Services
    let network: NetworkClient
    let canvasEvents = PassthroughSubject<CanvasEvent, Never>()
    private var cancellables = Set<AnyCancellable>()

    init(baseURL: URL) {
        self.userColorHex = SessionModel.randomPleasantColorHex()
        self.network = NetworkClient(serverURL: SessionModel.toWSURL(baseURL))
        wireNetwork()
    }

    /// Attach the logged-in user. Must be called before `switchRoom`.
    func configureAuth(user: AuthUser, token: String) {
        self.currentUser = user
        self.currentToken = token
    }

    /// Called when the user logs out — tear the WS connection down and clear
    /// all ephemeral state.
    func clearAuth() {
        network.disconnect()
        currentUser = nil
        currentToken = nil
        roomId = nil
        roomDisplayName = nil
        connectionState = .disconnected
        peerCount = 0
        peerCursors.removeAll()
        peerColorById.removeAll()
        currentPage = nil
    }

    /// Open a room (typically a DM with a friend). Disconnects the current WS
    /// connection first — `room_state` received on the new connection will
    /// reset the renderer via the normal canvas-event pipeline.
    func switchRoom(id: String, displayName: String) {
        guard let token = currentToken else { return }
        roomId = id
        roomDisplayName = displayName
        peerCursors.removeAll()
        peerColorById.removeAll()
        currentPage = nil
        connectionState = .connecting
        network.disconnect()
        network.connect(roomId: id, token: token, colorHex: userColorHex)
    }

    private static func toWSURL(_ httpURL: URL) -> URL {
        var comps = URLComponents(url: httpURL, resolvingAgainstBaseURL: false)!
        switch comps.scheme {
        case "https": comps.scheme = "wss"
        case "http":  comps.scheme = "ws"
        default: break
        }
        return comps.url ?? httpURL
    }

    private func wireNetwork() {
        network.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleNetworkEvent(event)
            }
            .store(in: &cancellables)
    }

    private func handleNetworkEvent(_ event: NetworkClient.Event) {
        switch event {
        case .opened:
            connectionState = .connected
        case .closed(let reason):
            connectionState = .failed(reason)
            peerCursors.removeAll()
            peerCount = 0
        case .roomState(let strokes, let peers, let page):
            peerCount = peers.count
            for p in peers { peerColorById[p.userId] = p.color }
            applyIncomingPage(page)
            canvasEvents.send(.roomState(strokes: strokes))
        case .peerJoined(let peer):
            peerCount += 1
            peerColorById[peer.userId] = peer.color
        case .peerLeft(let id):
            peerCount = max(0, peerCount - 1)
            peerCursors.removeValue(forKey: id)
            peerColorById.removeValue(forKey: id)
        case .strokeStart(let uid, let header, let firstPoint):
            canvasEvents.send(.peerStrokeStart(userId: uid, header: header, firstPoint: firstPoint))
        case .strokePoint(let uid, let strokeId, let point):
            canvasEvents.send(.peerStrokePoint(userId: uid, strokeId: strokeId, point: point))
        case .strokeEnd(let uid, let strokeId):
            canvasEvents.send(.peerStrokeEnd(userId: uid, strokeId: strokeId))
        case .cursor(let uid, let x, let y):
            let hex = peerColorById[uid] ?? "#888888"
            peerCursors[uid] = PeerCursor(userId: uid, x: x, y: y, colorHex: hex)
        case .pageChanged(_, let page):
            applyIncomingPage(page)
            canvasEvents.send(.pageChanged(page: page))
        case .canvasCleared:
            canvasEvents.send(.canvasCleared)
        }
    }

    private func applyIncomingPage(_ page: WirePage?) {
        guard let page = page else {
            currentPage = nil
            return
        }
        let data: Data? = page.imageBase64.isEmpty
            ? nil
            : Data(base64Encoded: page.imageBase64)
        currentPage = CurrentPage(
            pageId: page.pageId,
            displayName: page.displayName,
            imageData: data
        )
    }

    private static func randomPleasantColorHex() -> String {
        // HSL with medium saturation/lightness → pick a hue at random
        let hue = Double.random(in: 0..<1)
        let (r, g, b) = hslToRGB(h: hue, s: 0.65, l: 0.55)
        return String(format: "#%02X%02X%02X",
                      Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        func hueToRGB(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0/6 { return p + (q - p) * 6 * t }
            if t < 1.0/2 { return q }
            if t < 2.0/3 { return p + (q - p) * (2.0/3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return (hueToRGB(p, q, h + 1.0/3),
                hueToRGB(p, q, h),
                hueToRGB(p, q, h - 1.0/3))
    }
}
