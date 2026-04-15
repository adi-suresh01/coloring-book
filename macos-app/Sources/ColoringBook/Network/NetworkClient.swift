import Foundation
import Combine

/// WebSocket client. Publishes received events on `events`.
/// Owns a URLSessionWebSocketTask and auto-reconnects with a short backoff.
final class NetworkClient {
    enum Event {
        case opened
        case closed(String)
        case roomState(strokes: [Stroke], peers: [WirePeer], page: WirePage?)
        case peerJoined(WirePeer)
        case peerLeft(userId: String)
        case strokeStart(userId: String, header: StrokeHeader, firstPoint: StrokePoint)
        case strokePoint(userId: String, strokeId: String, point: StrokePoint)
        case strokeEnd(userId: String, strokeId: String)
        case cursor(userId: String, x: Double, y: Double)
        case pageChanged(userId: String, page: WirePage?)
        case canvasCleared(userId: String)
    }

    let events = PassthroughSubject<Event, Never>()

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let serverURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var shouldReconnect = false
    private var reconnectJob: Task<Void, Never>?
    private var connectionArgs: (room: String, token: String, color: String)?

    init(serverURL: URL) {
        self.serverURL = serverURL
        self.session = URLSession(configuration: .default)
    }

    /// Connect to a room. `token` is the auth session token — the server
    /// resolves the user from it, so we don't send userId/name separately.
    func connect(roomId: String, token: String, colorHex: String) {
        shouldReconnect = true
        connectionArgs = (roomId, token, colorHex)
        openConnection()
    }

    private func openConnection() {
        guard let args = connectionArgs else { return }

        var comps = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "room", value: args.room),
            URLQueryItem(name: "token", value: args.token),
            URLQueryItem(name: "color", value: args.color),
        ]
        guard let url = comps?.url else { return }

        let t = session.webSocketTask(with: url)
        // Default is 1 MB which can truncate page-import payloads (base64
        // PNGs often run 500 KB – 2 MB). 8 MB is plenty for any coloring
        // book page while still bounded.
        t.maximumMessageSize = 8 * 1024 * 1024
        self.task = t
        t.resume()
        events.send(.opened)
        receiveLoop(task: t)
    }

    private func receiveLoop(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.handleIncoming(message)
                // Only continue if this is still the active task
                if self.task === task {
                    self.receiveLoop(task: task)
                }
            case .failure(let error):
                self.events.send(.closed(error.localizedDescription))
                if self.shouldReconnect, self.task === task {
                    self.reconnectJob?.cancel()
                    self.reconnectJob = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if let self = self, self.shouldReconnect {
                            self.openConnection()
                        }
                    }
                }
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }
        guard let env = try? decoder.decode(ServerEnvelope.self, from: data) else { return }
        switch env.type {
        case "room_state":
            if let m = try? decoder.decode(RoomStateMessage.self, from: data) {
                events.send(.roomState(
                    strokes: m.strokes.map { $0.toStroke() },
                    peers: m.peers,
                    page: m.page
                ))
            }
        case "peer_joined":
            if let m = try? decoder.decode(PeerJoinedMessage.self, from: data) {
                events.send(.peerJoined(m.peer))
            }
        case "peer_left":
            if let m = try? decoder.decode(PeerLeftMessage.self, from: data) {
                events.send(.peerLeft(userId: m.userId))
            }
        case "stroke_start":
            if let m = try? decoder.decode(StrokeStartMessage.self, from: data) {
                let h = StrokeHeader(
                    id: m.stroke.id,
                    userId: m.stroke.userId,
                    tool: m.stroke.tool,
                    color: m.stroke.color,
                    brushSize: m.stroke.brushSize
                )
                events.send(.strokeStart(userId: m.userId, header: h, firstPoint: m.stroke.point))
            }
        case "stroke_point":
            if let m = try? decoder.decode(StrokePointMessage.self, from: data) {
                events.send(.strokePoint(userId: m.userId, strokeId: m.strokeId, point: m.point))
            }
        case "stroke_end":
            if let m = try? decoder.decode(StrokeEndMessage.self, from: data) {
                events.send(.strokeEnd(userId: m.userId, strokeId: m.strokeId))
            }
        case "cursor":
            if let m = try? decoder.decode(CursorMessage.self, from: data) {
                events.send(.cursor(userId: m.userId, x: m.x, y: m.y))
            }
        case "page_changed":
            if let m = try? decoder.decode(PageChangedMessage.self, from: data) {
                events.send(.pageChanged(userId: m.userId, page: m.page))
            }
        case "canvas_cleared":
            if let m = try? decoder.decode(CanvasClearedMessage.self, from: data) {
                events.send(.canvasCleared(userId: m.userId))
            }
        default:
            break
        }
    }

    func send(_ msg: ClientMessage) {
        guard let task = task else { return }
        do {
            let data = try encoder.encode(msg)
            guard let str = String(data: data, encoding: .utf8) else { return }
            task.send(.string(str)) { _ in /* swallow; reconnect will handle drops */ }
        } catch {
            // swallow encode errors
        }
    }

    func disconnect() {
        shouldReconnect = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}
