import Foundation
import CoreGraphics

struct StrokePoint: Codable, Equatable {
    let x: Double       // normalized 0..1 in canvas space
    let y: Double
    let pressure: Double
    let t: Double       // seconds since epoch
}

struct WireColor: Codable, Equatable {
    let r: Double
    let g: Double
    let b: Double
    let a: Double
}

struct StrokeHeader: Codable, Equatable {
    let id: String
    let userId: String
    let tool: Tool
    let color: WireColor
    let brushSize: Double
}

struct Stroke: Identifiable, Equatable {
    let id: String
    let userId: String
    let tool: Tool
    let color: WireColor
    let brushSize: Double
    var points: [StrokePoint]
    var complete: Bool
}
