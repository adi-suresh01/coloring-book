import SwiftUI
import UniformTypeIdentifiers

/// Side-panel section that shows the room's pages — preserved server-side
/// across reconnects — plus controls to add a new page (built-in template,
/// imported file, or webcam capture) or clear the active page's strokes.
///
/// Each room owns multiple pages with independent stroke history. Switching
/// between pages preserves both pages' progress.
struct PagePicker: View {
    @EnvironmentObject var session: SessionModel
    @State private var showCameraSheet = false
    @State private var showAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pages").font(.headline)
                Spacer()
                if let active = session.activePage {
                    Text(active.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Room's saved pages (server-synced).
            if session.pages.isEmpty {
                Text("No pages yet — add one below to start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                    spacing: 8
                ) {
                    ForEach(session.pages) { page in
                        PageThumbnail(
                            page: page,
                            isSelected: page.pageId == session.activePageId,
                            tap: { session.selectPage(page.pageId) },
                            delete: { session.deletePage(page.pageId) }
                        )
                    }
                }
            }

            // Add-new buttons — each creates a new page in the room.
            VStack(alignment: .leading, spacing: 6) {
                Button { showAddSheet = true } label: {
                    Label("Add built-in page…", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                Button { importColoringPage() } label: {
                    Label("Import coloring page…", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .help("Pick a clean PNG or JPG of a coloring page you downloaded.")

                Button { showCameraSheet = true } label: {
                    Label("Capture sketch from camera", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) { session.clearCanvas() } label: {
                    Label("Clear current page", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(session.activePageId == nil)
            }
            .padding(.top, 4)
        }
        .sheet(isPresented: $showCameraSheet) {
            CameraCaptureView { pngData in
                session.addPage(name: "Captured", imageData: pngData)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            BuiltInPagePickerSheet()
        }
    }

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
        session.addPage(
            name: url.deletingPathExtension().lastPathComponent,
            imageData: data
        )
    }
}

private struct PageThumbnail: View {
    let page: CurrentPage
    let isSelected: Bool
    let tap: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: tap) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.98, green: 0.96, blue: 0.90))
                if let data = page.imageData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
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
        .contextMenu {
            Button(role: .destructive) {
                delete()
            } label: {
                Label("Delete page", systemImage: "trash")
            }
        }
    }
}

private struct BuiltInPagePickerSheet: View {
    @EnvironmentObject var session: SessionModel
    @Environment(\.dismiss) private var dismiss

    private let templates = PageLibrary.builtIn()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick a built-in page").font(.headline)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                ForEach(templates, id: \.pageId) { template in
                    Button {
                        session.addPage(
                            name: template.displayName,
                            imageData: template.imageData
                        )
                        dismiss()
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(red: 0.98, green: 0.96, blue: 0.90))
                            if let data = template.imageData,
                               let img = NSImage(data: data) {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .padding(6)
                            }
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
                        }
                        .frame(height: 110)
                        .overlay(alignment: .bottom) {
                            Text(template.displayName)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.ultraThinMaterial,
                                            in: RoundedRectangle(cornerRadius: 4))
                                .padding(4)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 360)
    }
}
