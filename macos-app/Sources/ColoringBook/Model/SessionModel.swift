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
    /// Full snapshot on join / room switch. Renderer should clear and stamp
    /// only the strokes whose pageId matches `activePageId`.
    case roomState(activePageId: String?, strokes: [Stroke])
    case peerStrokeStart(
        userId: String,
        header: StrokeHeader,
        pageId: String,
        firstPoint: StrokePoint
    )
    case peerStrokePoint(userId: String, strokeId: String, point: StrokePoint)
    case peerStrokeEnd(userId: String, strokeId: String)
    /// Active page changed. Renderer should clear and stamp only the strokes
    /// whose pageId matches the new activePageId.
    case activePageChanged(pageId: String?)
    /// Active page's strokes were wiped.
    case activePageStrokesCleared(pageId: String)
}

struct CurrentPage: Equatable, Identifiable, Hashable {
    let pageId: String
    let displayName: String
    let imageData: Data?   // nil = blank paper

    var id: String { pageId }
}

@MainActor
final class SessionModel: ObservableObject {
    // MARK: Drawing state (UI-facing)
    @Published var tool: Tool = .sketchpen
    @Published var color: ArtColor = ArtColor.defaultInk
    @Published var brushSize: CGFloat = Tool.sketchpen.defaultBrushSize

    @Published var isInCanvasMode: Bool = false
    func toggleCanvasMode() { isInCanvasMode.toggle() }

    // MARK: Pages — server-synced multi-page state per room.
    @Published var pages: [CurrentPage] = []
    @Published var activePageId: String? = nil

    /// All strokes across all pages (kept so we can re-stamp when the active
    /// page changes). Filled from `room_state` and updated as new strokes
    /// arrive.
    private var strokesByPage: [String: [Stroke]] = [:]

    /// The active page's metadata — convenience for views.
    var activePage: CurrentPage? {
        guard let id = activePageId else { return nil }
        return pages.first { $0.pageId == id }
    }

    /// Add a new page to the room. The server creates the row and broadcasts
    /// `page_added` + `page_selected`; this method also updates local state
    /// optimistically so UI is responsive.
    func addPage(name: String, imageData: Data?) {
        let pageId = UUID().uuidString
        let new = CurrentPage(pageId: pageId, displayName: name, imageData: imageData)
        // Optimistic local update; server will confirm via page_added event.
        pages.append(new)
        activePageId = pageId
        strokesByPage[pageId] = []
        canvasEvents.send(.activePageChanged(pageId: pageId))

        let wire = WirePage(
            pageId: pageId,
            displayName: name,
            mimeType: "image/png",
            imageBase64: imageData?.base64EncodedString() ?? ""
        )
        network.send(.addPage(wire))
    }

    /// Switch which page is active.
    func selectPage(_ pageId: String) {
        guard pages.contains(where: { $0.pageId == pageId }),
              activePageId != pageId else { return }
        activePageId = pageId
        canvasEvents.send(.activePageChanged(pageId: pageId))
        network.send(.selectPage(pageId: pageId))
    }

    /// Remove a page (and its strokes).
    func deletePage(_ pageId: String) {
        pages.removeAll { $0.pageId == pageId }
        strokesByPage.removeValue(forKey: pageId)
        if activePageId == pageId {
            activePageId = pages.first?.pageId
            canvasEvents.send(.activePageChanged(pageId: activePageId))
        }
        network.send(.deletePage(pageId: pageId))
    }

    /// Clears the *active* page's strokes only.
    func clearCanvas() {
        guard let id = activePageId else { return }
        strokesByPage[id] = []
        canvasEvents.send(.activePageStrokesCleared(pageId: id))
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
        pages = []
        activePageId = nil
        strokesByPage.removeAll()
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
        pages = []
        activePageId = nil
        strokesByPage.removeAll()
        connectionState = .connecting
        network.disconnect()
        network.connect(roomId: id, token: token, colorHex: userColorHex)
    }

    /// Strokes for the active page only. Used by the renderer to repaint when
    /// the active page changes.
    func strokesForActivePage() -> [Stroke] {
        guard let id = activePageId else { return [] }
        return strokesByPage[id] ?? []
    }

    /// Append a stroke into the per-page index (used when a new stroke
    /// arrives from a peer or is finalized locally).
    fileprivate func recordStroke(_ stroke: Stroke) {
        strokesByPage[stroke.pageId, default: []].append(stroke)
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
        case .roomState(let strokes, let peers, let wirePages, let active):
            peerCount = peers.count
            for p in peers { peerColorById[p.userId] = p.color }
            // Replace pages list with server's authoritative state.
            pages = wirePages.map { wireToPage($0) }
            activePageId = active
            // Demux strokes by pageId.
            strokesByPage.removeAll()
            for s in strokes {
                strokesByPage[s.pageId, default: []].append(s)
            }
            canvasEvents.send(.roomState(activePageId: active, strokes: strokes))
        case .peerJoined(let peer):
            peerCount += 1
            peerColorById[peer.userId] = peer.color
        case .peerLeft(let id):
            peerCount = max(0, peerCount - 1)
            peerCursors.removeValue(forKey: id)
            peerColorById.removeValue(forKey: id)
        case .strokeStart(let uid, let header, let pageId, let firstPoint):
            canvasEvents.send(.peerStrokeStart(
                userId: uid, header: header, pageId: pageId, firstPoint: firstPoint
            ))
        case .strokePoint(let uid, let strokeId, let point):
            canvasEvents.send(.peerStrokePoint(userId: uid, strokeId: strokeId, point: point))
        case .strokeEnd(let uid, let strokeId):
            canvasEvents.send(.peerStrokeEnd(userId: uid, strokeId: strokeId))
        case .cursor(let uid, let x, let y):
            let hex = peerColorById[uid] ?? "#888888"
            peerCursors[uid] = PeerCursor(userId: uid, x: x, y: y, colorHex: hex)
        case .pageAdded(_, let page):
            let cp = wireToPage(page)
            if !pages.contains(where: { $0.pageId == cp.pageId }) {
                pages.append(cp)
            }
        case .pageSelected(_, let pageId):
            if activePageId != pageId {
                activePageId = pageId
                canvasEvents.send(.activePageChanged(pageId: pageId))
            }
        case .pageDeleted(_, let pageId):
            pages.removeAll { $0.pageId == pageId }
            strokesByPage.removeValue(forKey: pageId)
            if activePageId == pageId {
                activePageId = pages.first?.pageId
                canvasEvents.send(.activePageChanged(pageId: activePageId))
            }
        case .canvasCleared(_, let pageId):
            strokesByPage[pageId] = []
            if activePageId == pageId {
                canvasEvents.send(.activePageStrokesCleared(pageId: pageId))
            }
        }
    }

    private func wireToPage(_ wire: WirePage) -> CurrentPage {
        let data = wire.imageBase64.isEmpty
            ? nil
            : Data(base64Encoded: wire.imageBase64)
        return CurrentPage(
            pageId: wire.pageId,
            displayName: wire.displayName,
            imageData: data
        )
    }

    /// Called by CanvasCoordinator when a local stroke completes (so it's
    /// available for re-stamping when the user switches pages).
    func _recordLocalStroke(_ stroke: Stroke) {
        recordStroke(stroke)
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
