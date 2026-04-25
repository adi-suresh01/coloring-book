import SwiftUI

struct ColorPalette: View {
    @EnvironmentObject var session: SessionModel

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 5),
        count: 6
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ArtColor.families, id: \.self) { family in
                FamilyBlock(family: family, columns: columns)
            }
        }
    }
}

private struct FamilyBlock: View {
    let family: String
    let columns: [GridItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(family.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .tracking(0.8)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(ArtColor.colors(in: family)) { color in
                    Swatch(color: color)
                }
            }
        }
    }
}

private struct Swatch: View {
    @EnvironmentObject var session: SessionModel
    let color: ArtColor

    var body: some View {
        Button { session.color = color } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(color.swiftUIColor)
                .frame(height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            color == session.color
                                ? Color.primary
                                : Color.black.opacity(0.18),
                            lineWidth: color == session.color ? 2.2 : 1
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
