import SwiftUI

struct ToolPicker: View {
    @EnvironmentObject var session: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tool").font(.headline)
            ForEach(Tool.allCases) { t in
                Button {
                    session.tool = t
                    session.brushSize = t.defaultBrushSize
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: t))
                            .frame(width: 18)
                        Text(t.displayName)
                        Spacer()
                        if t == session.tool {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(t == session.tool
                                  ? Color.accentColor.opacity(0.12)
                                  : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Size").font(.caption)
                    Spacer()
                    Text(String(format: "%.1f", session.brushSize))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $session.brushSize, in: 0.5...20)
            }
            .padding(.top, 6)
        }
    }

    private func icon(for tool: Tool) -> String {
        switch tool {
        case .sketchpen:  return "highlighter"
        case .pencil:     return "pencil"
        case .watercolor: return "paintbrush.pointed.fill"
        case .crayon:     return "pencil.tip.crop.circle.fill"
        case .pastel:     return "paintbrush"
        }
    }
}
