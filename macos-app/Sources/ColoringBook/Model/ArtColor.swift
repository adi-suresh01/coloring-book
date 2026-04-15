import SwiftUI

struct ArtColor: Equatable, Identifiable, Codable {
    let id: String
    let name: String
    let r: Double
    let g: Double
    let b: Double

    var swiftUIColor: Color { Color(red: r, green: g, blue: b) }

    static let palette: [ArtColor] = [
        .init(id: "ink-black",   name: "Ink Black",    r: 0.08, g: 0.08, b: 0.10),
        .init(id: "graphite",    name: "Graphite",     r: 0.30, g: 0.32, b: 0.36),
        .init(id: "cherry-red",  name: "Cherry Red",   r: 0.86, g: 0.18, b: 0.18),
        .init(id: "coral",       name: "Coral",        r: 0.98, g: 0.51, b: 0.45),
        .init(id: "sunset",      name: "Sunset",       r: 0.96, g: 0.42, b: 0.30),
        .init(id: "orange",      name: "Orange",       r: 0.98, g: 0.63, b: 0.12),
        .init(id: "amber",       name: "Amber",        r: 0.98, g: 0.80, b: 0.20),
        .init(id: "lemon",       name: "Lemon",        r: 0.99, g: 0.95, b: 0.28),
        .init(id: "lime",        name: "Lime",         r: 0.68, g: 0.88, b: 0.28),
        .init(id: "grass",       name: "Grass Green",  r: 0.30, g: 0.72, b: 0.28),
        .init(id: "forest",      name: "Forest",       r: 0.08, g: 0.45, b: 0.28),
        .init(id: "teal",        name: "Teal",         r: 0.12, g: 0.66, b: 0.66),
        .init(id: "sky",         name: "Sky",          r: 0.42, g: 0.80, b: 0.98),
        .init(id: "azure",       name: "Azure",        r: 0.18, g: 0.50, b: 0.96),
        .init(id: "indigo",      name: "Indigo",       r: 0.30, g: 0.26, b: 0.74),
        .init(id: "violet",      name: "Violet",       r: 0.56, g: 0.34, b: 0.86),
        .init(id: "magenta",     name: "Magenta",      r: 0.92, g: 0.28, b: 0.72),
        .init(id: "pink",        name: "Pink",         r: 0.98, g: 0.60, b: 0.82),
        .init(id: "rose",        name: "Rose",         r: 0.94, g: 0.42, b: 0.58),
        .init(id: "brown",       name: "Brown",        r: 0.52, g: 0.32, b: 0.18),
        .init(id: "sand",        name: "Sand",         r: 0.90, g: 0.76, b: 0.52),
        .init(id: "mint",        name: "Mint",         r: 0.62, g: 0.92, b: 0.78),
        .init(id: "lavender",    name: "Lavender",     r: 0.76, g: 0.68, b: 0.96),
        .init(id: "slate",       name: "Slate",        r: 0.46, g: 0.52, b: 0.62),
    ]
}
