import SwiftUI
import UniformTypeIdentifiers

struct PagePicker: View {
    @EnvironmentObject var session: SessionModel
    @State private var showCameraSheet = false

    private let pages = PageLibrary.builtIn()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Page").font(.headline)
                Spacer()
                if let page = session.currentPage {
                    Text(page.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                      spacing: 8) {
                ForEach(pages, id: \.pageId) { page in
                    PageThumbnail(page: page,
                                  isSelected: page.pageId == session.currentPage?.pageId) {
                        session.setPage(page)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    importColoringPage()
                } label: {
                    Label("Import coloring page…", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .help("Pick a clean PNG or JPG of a coloring page you downloaded.")

                Button {
                    showCameraSheet = true
                } label: {
                    Label("Capture sketch from camera", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .help("Use the webcam to scan a hand-drawn sketch.")

                Button(role: .destructive) {
                    session.clearCanvas()
                } label: {
                    Label("Clear canvas", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .sheet(isPresented: $showCameraSheet) {
            CameraCaptureView { pngData in
                let page = CurrentPage(
                    pageId: "capture-\(UUID().uuidString)",
                    displayName: "Captured",
                    imageData: pngData
                )
                session.setPage(page)
            }
        }
    }

    /// Direct import path for clean PNG/JPG coloring pages — just desaturate
    /// and convert the background to transparent. No document detection, no
    /// perspective correction, no thresholding.
    private func importColoringPage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Pick a coloring book page (PNG or JPG)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = VisionLineExtractor.loadColoringPage(from: url) else {
            NSLog("Failed to load coloring page \(url.lastPathComponent)")
            return
        }
        let page = CurrentPage(
            pageId: "import-\(UUID().uuidString)",
            displayName: url.deletingPathExtension().lastPathComponent,
            imageData: data
        )
        session.setPage(page)
    }
}

private struct PageThumbnail: View {
    let page: CurrentPage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.98, green: 0.96, blue: 0.90))
                if let data = page.imageData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    // Blank paper placeholder: a cream swatch
                    EmptyView()
                }
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.black.opacity(0.15),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .frame(height: 62)
            .overlay(alignment: .bottom) {
                Text(page.displayName)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }
        }
        .buttonStyle(.plain)
    }
}
