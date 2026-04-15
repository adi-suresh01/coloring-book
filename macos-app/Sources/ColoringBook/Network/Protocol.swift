import Foundation

// MARK: Outgoing (Client → Server)

enum ClientMessage: Encodable {
    case strokeStart(StrokeStartPayload)
    case strokePoint(strokeId: String, point: StrokePoint)
    case strokeEnd(strokeId: String)
    case cursor(x: Double, y: Double)
    case setPage(WirePage?)
    case clearCanvas

    private enum CodingKeys: String, CodingKey {
        case type, stroke, strokeId, point, x, y, page
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .strokeStart(let p):
            try c.encode("stroke_start", forKey: .type)
            try c.encode(p, forKey: .stroke)
        case .strokePoint(let strokeId, let point):
            try c.encode("stroke_point", forKey: .type)
            try c.encode(strokeId, forKey: .strokeId)
            try c.encode(point, forKey: .point)
        case .strokeEnd(let strokeId):
            try c.encode("stroke_end", forKey: .type)
            try c.encode(strokeId, forKey: .strokeId)
        case .cursor(let x, let y):
            try c.encode("cursor", forKey: .type)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        case .setPage(let page):
            try c.encode("set_page", forKey: .type)
            try c.encode(page, forKey: .page)
        case .clearCanvas:
            try c.encode("clear_canvas", forKey: .type)
        }
    }
}

/// A page of line art (transparent PNG) shared across a room. The `imageBase64`
/// may be an empty string for blank-paper pages.
struct WirePage: Codable, Equatable {
    let pageId: String
    let displayName: String
    let mimeType: String
    let imageBase64: String
}

struct StrokeStartPayload: Codable {
    let id: String
    let userId: String
    let tool: Tool
    let color: WireColor
    let brushSize: Double
    let point: StrokePoint
}

// MARK: Incoming (Server → Client)

struct ServerEnvelope: Decodable { let type: String }

struct WireStroke: Decodable {
    let id: String
    let userId: String
    let tool: Tool
    let color: WireColor
    let brushSize: Double
    let points: [StrokePoint]
    let complete: Bool

    func toStroke() -> Stroke {
        Stroke(id: id, userId: userId, tool: tool, color: color,
               brushSize: brushSize, points: points, complete: complete)
    }
}

struct WirePeer: Decodable {
    let userId: String
    let name: String
    let color: String
}

struct RoomStateMessage: Decodable {
    let strokes: [WireStroke]
    let peers: [WirePeer]
    let you: You
    let page: WirePage?
    struct You: Decodable { let userId: String }
}

struct PageChangedMessage: Decodable {
    let userId: String
    let page: WirePage?
}

struct CanvasClearedMessage: Decodable {
    let userId: String
}

struct PeerJoinedMessage: Decodable { let peer: WirePeer }
struct PeerLeftMessage: Decodable { let userId: String }

struct WireStrokeStart: Decodable {
    let id: String
    let userId: String
    let tool: Tool
    let color: WireColor
    let brushSize: Double
    let point: StrokePoint
}

struct StrokeStartMessage: Decodable {
    let userId: String
    let stroke: WireStrokeStart
}

struct StrokePointMessage: Decodable {
    let userId: String
    let strokeId: String
    let point: StrokePoint
}

struct StrokeEndMessage: Decodable {
    let userId: String
    let strokeId: String
}

struct CursorMessage: Decodable {
    let userId: String
    let x: Double
    let y: Double
}
