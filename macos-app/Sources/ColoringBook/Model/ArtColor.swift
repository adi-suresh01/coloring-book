import SwiftUI

struct ArtColor: Equatable, Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let family: String
    let r: Double
    let g: Double
    let b: Double

    var swiftUIColor: Color { Color(red: r, green: g, blue: b) }

    // MARK: Palette (≈100 colors, 10 families, flows neutral → warm → cool)

    static let palette: [ArtColor] = [

        // ----- NEUTRALS (8) -------------------------------------------------
        .init(id: "ink-black",  name: "Ink Black",  family: "Neutrals", r: 0.06, g: 0.06, b: 0.08),
        .init(id: "charcoal",   name: "Charcoal",   family: "Neutrals", r: 0.18, g: 0.19, b: 0.22),
        .init(id: "graphite",   name: "Graphite",   family: "Neutrals", r: 0.34, g: 0.36, b: 0.40),
        .init(id: "slate",      name: "Slate",      family: "Neutrals", r: 0.48, g: 0.53, b: 0.60),
        .init(id: "dove",       name: "Dove",       family: "Neutrals", r: 0.64, g: 0.66, b: 0.70),
        .init(id: "fog",        name: "Fog",        family: "Neutrals", r: 0.80, g: 0.82, b: 0.84),
        .init(id: "pearl",      name: "Pearl",      family: "Neutrals", r: 0.90, g: 0.91, b: 0.93),
        .init(id: "snow",       name: "Snow",       family: "Neutrals", r: 0.98, g: 0.98, b: 0.99),

        // ----- REDS (12) ----------------------------------------------------
        .init(id: "burgundy",   name: "Burgundy",   family: "Reds", r: 0.42, g: 0.10, b: 0.18),
        .init(id: "wine",       name: "Wine",       family: "Reds", r: 0.55, g: 0.14, b: 0.22),
        .init(id: "crimson",    name: "Crimson",    family: "Reds", r: 0.78, g: 0.10, b: 0.22),
        .init(id: "cherry-red", name: "Cherry Red", family: "Reds", r: 0.86, g: 0.18, b: 0.18),
        .init(id: "scarlet",    name: "Scarlet",    family: "Reds", r: 0.98, g: 0.22, b: 0.18),
        .init(id: "sunset",     name: "Sunset",     family: "Reds", r: 0.96, g: 0.42, b: 0.30),
        .init(id: "coral",      name: "Coral",      family: "Reds", r: 0.98, g: 0.51, b: 0.45),
        .init(id: "salmon",     name: "Salmon",     family: "Reds", r: 0.98, g: 0.63, b: 0.56),
        .init(id: "rose",       name: "Rose",       family: "Reds", r: 0.94, g: 0.42, b: 0.58),
        .init(id: "tea-rose",   name: "Tea Rose",   family: "Reds", r: 0.96, g: 0.68, b: 0.70),
        .init(id: "blush",      name: "Blush",      family: "Reds", r: 0.98, g: 0.78, b: 0.80),
        .init(id: "shell-pink", name: "Shell",      family: "Reds", r: 0.99, g: 0.88, b: 0.86),

        // ----- ORANGES (8) --------------------------------------------------
        .init(id: "rust",         name: "Rust",       family: "Oranges", r: 0.66, g: 0.28, b: 0.12),
        .init(id: "burnt-orange", name: "Burnt Org.", family: "Oranges", r: 0.82, g: 0.40, b: 0.12),
        .init(id: "pumpkin",      name: "Pumpkin",    family: "Oranges", r: 0.92, g: 0.48, b: 0.10),
        .init(id: "orange",       name: "Orange",     family: "Oranges", r: 0.98, g: 0.58, b: 0.14),
        .init(id: "tangerine",    name: "Tangerine",  family: "Oranges", r: 0.98, g: 0.68, b: 0.26),
        .init(id: "apricot",      name: "Apricot",    family: "Oranges", r: 0.98, g: 0.76, b: 0.48),
        .init(id: "peach",        name: "Peach",      family: "Oranges", r: 0.99, g: 0.82, b: 0.67),
        .init(id: "cream",        name: "Cream",      family: "Oranges", r: 0.99, g: 0.92, b: 0.80),

        // ----- YELLOWS (8) --------------------------------------------------
        .init(id: "mustard",    name: "Mustard",    family: "Yellows", r: 0.76, g: 0.58, b: 0.14),
        .init(id: "goldenrod",  name: "Goldenrod",  family: "Yellows", r: 0.88, g: 0.72, b: 0.18),
        .init(id: "amber",      name: "Amber",      family: "Yellows", r: 0.98, g: 0.80, b: 0.20),
        .init(id: "gold",       name: "Gold",       family: "Yellows", r: 0.98, g: 0.88, b: 0.22),
        .init(id: "lemon",      name: "Lemon",      family: "Yellows", r: 0.99, g: 0.95, b: 0.28),
        .init(id: "banana",     name: "Banana",     family: "Yellows", r: 0.99, g: 0.95, b: 0.56),
        .init(id: "butter",     name: "Butter",     family: "Yellows", r: 0.99, g: 0.96, b: 0.72),
        .init(id: "cornsilk",   name: "Cornsilk",   family: "Yellows", r: 0.99, g: 0.98, b: 0.86),

        // ----- GREENS (12) --------------------------------------------------
        .init(id: "pine",       name: "Pine",       family: "Greens", r: 0.06, g: 0.26, b: 0.18),
        .init(id: "forest",     name: "Forest",     family: "Greens", r: 0.08, g: 0.38, b: 0.24),
        .init(id: "evergreen",  name: "Evergreen",  family: "Greens", r: 0.12, g: 0.48, b: 0.30),
        .init(id: "emerald",    name: "Emerald",    family: "Greens", r: 0.12, g: 0.60, b: 0.38),
        .init(id: "grass",      name: "Grass",      family: "Greens", r: 0.28, g: 0.72, b: 0.30),
        .init(id: "leaf",       name: "Leaf",       family: "Greens", r: 0.44, g: 0.78, b: 0.32),
        .init(id: "lime",       name: "Lime",       family: "Greens", r: 0.68, g: 0.88, b: 0.28),
        .init(id: "apple-green", name: "Apple",     family: "Greens", r: 0.62, g: 0.80, b: 0.40),
        .init(id: "sage",       name: "Sage",       family: "Greens", r: 0.58, g: 0.72, b: 0.55),
        .init(id: "mint",       name: "Mint",       family: "Greens", r: 0.62, g: 0.92, b: 0.78),
        .init(id: "olive",      name: "Olive",      family: "Greens", r: 0.50, g: 0.55, b: 0.22),
        .init(id: "pear",       name: "Pear",       family: "Greens", r: 0.82, g: 0.88, b: 0.45),

        // ----- TEALS (8) ----------------------------------------------------
        .init(id: "deep-teal",  name: "Deep Teal",  family: "Teals", r: 0.06, g: 0.32, b: 0.36),
        .init(id: "teal",       name: "Teal",       family: "Teals", r: 0.12, g: 0.55, b: 0.60),
        .init(id: "turquoise",  name: "Turquoise",  family: "Teals", r: 0.16, g: 0.72, b: 0.70),
        .init(id: "aqua",       name: "Aqua",       family: "Teals", r: 0.28, g: 0.82, b: 0.80),
        .init(id: "cyan",       name: "Cyan",       family: "Teals", r: 0.30, g: 0.88, b: 0.92),
        .init(id: "sea-foam",   name: "Sea Foam",   family: "Teals", r: 0.60, g: 0.86, b: 0.78),
        .init(id: "pale-aqua",  name: "Pale Aqua",  family: "Teals", r: 0.76, g: 0.92, b: 0.90),
        .init(id: "ice",        name: "Ice",        family: "Teals", r: 0.88, g: 0.96, b: 0.96),

        // ----- BLUES (12) ---------------------------------------------------
        .init(id: "midnight",    name: "Midnight",   family: "Blues", r: 0.06, g: 0.10, b: 0.24),
        .init(id: "navy",        name: "Navy",       family: "Blues", r: 0.08, g: 0.18, b: 0.44),
        .init(id: "royal-blue",  name: "Royal Blue", family: "Blues", r: 0.14, g: 0.30, b: 0.74),
        .init(id: "cobalt",      name: "Cobalt",     family: "Blues", r: 0.12, g: 0.38, b: 0.80),
        .init(id: "sapphire",    name: "Sapphire",   family: "Blues", r: 0.18, g: 0.42, b: 0.82),
        .init(id: "azure",       name: "Azure",      family: "Blues", r: 0.18, g: 0.50, b: 0.96),
        .init(id: "denim",       name: "Denim",      family: "Blues", r: 0.36, g: 0.52, b: 0.72),
        .init(id: "steel-blue",  name: "Steel Blue", family: "Blues", r: 0.44, g: 0.64, b: 0.82),
        .init(id: "sky",         name: "Sky",        family: "Blues", r: 0.42, g: 0.80, b: 0.98),
        .init(id: "cornflower",  name: "Cornflower", family: "Blues", r: 0.56, g: 0.72, b: 0.92),
        .init(id: "baby-blue",   name: "Baby Blue",  family: "Blues", r: 0.72, g: 0.86, b: 0.95),
        .init(id: "powder",      name: "Powder",     family: "Blues", r: 0.84, g: 0.92, b: 0.96),

        // ----- PURPLES (12) -------------------------------------------------
        .init(id: "eggplant",      name: "Eggplant",     family: "Purples", r: 0.24, g: 0.14, b: 0.36),
        .init(id: "indigo",        name: "Indigo",       family: "Purples", r: 0.30, g: 0.26, b: 0.74),
        .init(id: "royal-purple",  name: "Royal Purple", family: "Purples", r: 0.42, g: 0.30, b: 0.76),
        .init(id: "violet",        name: "Violet",       family: "Purples", r: 0.56, g: 0.34, b: 0.86),
        .init(id: "amethyst",      name: "Amethyst",     family: "Purples", r: 0.62, g: 0.42, b: 0.78),
        .init(id: "plum",          name: "Plum",         family: "Purples", r: 0.55, g: 0.25, b: 0.55),
        .init(id: "grape",         name: "Grape",        family: "Purples", r: 0.48, g: 0.32, b: 0.62),
        .init(id: "orchid",        name: "Orchid",       family: "Purples", r: 0.85, g: 0.60, b: 0.88),
        .init(id: "lilac",         name: "Lilac",        family: "Purples", r: 0.82, g: 0.72, b: 0.92),
        .init(id: "lavender",      name: "Lavender",     family: "Purples", r: 0.78, g: 0.70, b: 0.94),
        .init(id: "wisteria",      name: "Wisteria",     family: "Purples", r: 0.78, g: 0.75, b: 0.88),
        .init(id: "mauve",         name: "Mauve",        family: "Purples", r: 0.88, g: 0.72, b: 0.82),

        // ----- PINKS (10) ---------------------------------------------------
        .init(id: "raspberry",    name: "Raspberry",  family: "Pinks", r: 0.82, g: 0.20, b: 0.50),
        .init(id: "magenta",      name: "Magenta",    family: "Pinks", r: 0.92, g: 0.28, b: 0.72),
        .init(id: "hot-pink",     name: "Hot Pink",   family: "Pinks", r: 0.98, g: 0.30, b: 0.62),
        .init(id: "fuchsia",      name: "Fuchsia",    family: "Pinks", r: 0.92, g: 0.40, b: 0.80),
        .init(id: "pink",         name: "Pink",       family: "Pinks", r: 0.98, g: 0.60, b: 0.82),
        .init(id: "bubblegum",    name: "Bubblegum",  family: "Pinks", r: 1.00, g: 0.58, b: 0.74),
        .init(id: "carnation",    name: "Carnation",  family: "Pinks", r: 0.98, g: 0.70, b: 0.78),
        .init(id: "rose-pink",    name: "Rose Pink",  family: "Pinks", r: 0.98, g: 0.76, b: 0.82),
        .init(id: "cotton-candy", name: "Cotton Candy", family: "Pinks", r: 0.99, g: 0.85, b: 0.90),
        .init(id: "baby-pink",    name: "Baby Pink",  family: "Pinks", r: 0.99, g: 0.92, b: 0.94),

        // ----- BROWNS & EARTH (12) ------------------------------------------
        .init(id: "espresso",  name: "Espresso",  family: "Browns", r: 0.20, g: 0.12, b: 0.08),
        .init(id: "chocolate", name: "Chocolate", family: "Browns", r: 0.36, g: 0.20, b: 0.12),
        .init(id: "coffee",    name: "Coffee",    family: "Browns", r: 0.48, g: 0.30, b: 0.18),
        .init(id: "chestnut",  name: "Chestnut",  family: "Browns", r: 0.55, g: 0.28, b: 0.16),
        .init(id: "brown",     name: "Brown",     family: "Browns", r: 0.52, g: 0.34, b: 0.20),
        .init(id: "caramel",   name: "Caramel",   family: "Browns", r: 0.70, g: 0.46, b: 0.22),
        .init(id: "hazelnut",  name: "Hazelnut",  family: "Browns", r: 0.70, g: 0.52, b: 0.35),
        .init(id: "tan",       name: "Tan",       family: "Browns", r: 0.82, g: 0.68, b: 0.48),
        .init(id: "sand",      name: "Sand",      family: "Browns", r: 0.90, g: 0.76, b: 0.52),
        .init(id: "beige",     name: "Beige",     family: "Browns", r: 0.94, g: 0.86, b: 0.72),
        .init(id: "taupe",     name: "Taupe",     family: "Browns", r: 0.72, g: 0.66, b: 0.58),
        .init(id: "khaki",     name: "Khaki",     family: "Browns", r: 0.78, g: 0.72, b: 0.48),
    ]

    /// Default ink color selected on a fresh launch.
    static var defaultInk: ArtColor {
        palette.first { $0.id == "cherry-red" } ?? palette[0]
    }

    /// Families in display order (derived from the palette's natural ordering).
    static var families: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for c in palette where !seen.contains(c.family) {
            seen.insert(c.family)
            result.append(c.family)
        }
        return result
    }

    static func colors(in family: String) -> [ArtColor] {
        palette.filter { $0.family == family }
    }
}
