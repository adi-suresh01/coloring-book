import Foundation

enum Tool: String, Codable, CaseIterable, Identifiable {
    case sketchpen
    case pencil
    case watercolor
    case crayon
    case pastel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sketchpen: return "Sketch Pen"
        case .pencil:    return "Color Pencil"
        case .watercolor:return "Watercolor"
        case .crayon:    return "Crayon"
        case .pastel:    return "Pastel"
        }
    }

    var defaultBrushSize: CGFloat {
        switch self {
        case .sketchpen: return 3
        case .pencil:    return 1.5
        case .watercolor:return 11
        case .crayon:    return 6
        case .pastel:    return 8
        }
    }

    /// Fragment-function name in `Shaders.source` used to stamp this tool.
    var shaderFragmentName: String {
        switch self {
        case .sketchpen: return "brush_sketchpen_fragment"
        case .pencil:    return "brush_pencil_fragment"
        case .watercolor:return "brush_watercolor_fragment"
        case .crayon:    return "brush_crayon_fragment"
        case .pastel:    return "brush_pastel_fragment"
        }
    }
}
