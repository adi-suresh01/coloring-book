import SwiftUI

struct ContentView: View {
    @EnvironmentObject var session: SessionModel

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                DeskBackground()
                if session.roomId != nil {
                    PageFrame {
                        CanvasView()
                    }
                    .padding(24)
                } else {
                    NoRoomPlaceholder()
                }
            }
            Divider()
            SidePanel()
                .frame(width: 300)
        }
    }
}

private struct NoRoomPlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.4))
            Text("Pick a friend from the panel to start drawing.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.75))
            Text("Or add one with the + button.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Dark desk-tone surround so the canvas reads as a page lying on a desk.
private struct DeskBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.17, green: 0.13, blue: 0.10),
                    Color(red: 0.12, green: 0.09, blue: 0.07),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // A very subtle radial highlight behind the page, as if a lamp
            // above is pointing at the book.
            RadialGradient(
                colors: [
                    Color.white.opacity(0.06),
                    Color.clear,
                ],
                center: .center,
                startRadius: 60,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

/// Frames the canvas with a warm paper-edge ring and a soft drop shadow so
/// the whole thing feels like a printed page resting on the desk.
private struct PageFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .overlay(
                // Thin cream edge highlight on top of the paper rim
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(red: 1, green: 0.96, blue: 0.88).opacity(0.35),
                                  lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 12)
            .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
    }
}

