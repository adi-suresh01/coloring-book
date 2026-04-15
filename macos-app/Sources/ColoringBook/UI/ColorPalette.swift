import SwiftUI

struct ColorPalette: View {
    @EnvironmentObject var session: SessionModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(ArtColor.palette) { color in
                Button {
                    session.color = color
                } label: {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(color.swiftUIColor)
                        .frame(height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    color == session.color
                                        ? Color.primary
                                        : Color.black.opacity(0.18),
                                    lineWidth: color == session.color ? 2.5 : 1
                                )
                        )
                        .shadow(
                            color: color == session.color
                                ? Color.black.opacity(0.25)
                                : .clear,
                            radius: 2, y: 1
                        )
                }
                .buttonStyle(.plain)
                .help(color.name)
            }
        }
    }
}
