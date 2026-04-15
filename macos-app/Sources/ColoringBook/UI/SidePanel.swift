import SwiftUI

struct SidePanel: View {
    @EnvironmentObject var session: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FriendsPanel()
                    if session.roomId != nil {
                        Divider()
                        ToolPicker()
                        Divider()
                        PagePicker()
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Palette").font(.headline)
                            ColorPalette()
                        }
                        Divider()
                        SwatchPreview()
                    }
                }
                .padding()
            }

            Spacer(minLength: 0)
            GestureHelpFooter()
        }
        .background(.ultraThinMaterial)
    }
}

private struct SwatchPreview: View {
    @EnvironmentObject var session: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current color").font(.headline)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(session.color.swiftUIColor)
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.black.opacity(0.2), lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.color.name).font(.subheadline).fontWeight(.medium)
                    Text(session.tool.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

private struct GestureHelpFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How to color").font(.caption).fontWeight(.semibold)
            Text("The trackpad is the paper. One finger presses the pen to paper and colors. Two fingers lift the pen so you can move without inking.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.04))
    }
}
