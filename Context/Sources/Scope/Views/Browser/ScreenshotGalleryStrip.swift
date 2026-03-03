import SwiftUI
import GRDB

struct ScreenshotGalleryStrip: View {
    let projectId: String

    @State private var screenshots: [BrowserScreenshot] = []
    @State private var isExpanded = false
    @State private var copiedScreenshotId: Int64?

    var body: some View {
        VStack(spacing: 0) {
            // Toggle bar
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 10)

                    Text("Screenshots (\(screenshots.count))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if screenshots.isEmpty {
                    Text("No screenshots yet")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(screenshots) { screenshot in
                                screenshotThumbnail(screenshot)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadScreenshots() }
        .onReceive(NotificationCenter.default.publisher(for: .screenshotsDidChange)) { _ in
            loadScreenshots()
        }
    }

    @ViewBuilder
    private func screenshotThumbnail(_ screenshot: BrowserScreenshot) -> some View {
        let fileURL = URL(fileURLWithPath: screenshot.filePath)
        if let image = NSImage(contentsOfFile: screenshot.filePath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                )
                // "Copied!" overlay
                .overlay {
                    if copiedScreenshotId == screenshot.id {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.black.opacity(0.6))
                            .overlay(
                                Text("Copied!")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.white)
                            )
                            .transition(.opacity)
                    }
                }
                .help(screenshot.pageTitle ?? screenshot.pageURL ?? "Screenshot")
                // Click: copy path to clipboard
                .onTapGesture {
                    copyPath(screenshot)
                }
                // Drag: provide as file URL
                .onDrag {
                    NSItemProvider(contentsOf: fileURL) ?? NSItemProvider()
                }
                // Right-click: context menu
                .contextMenu {
                    Button {
                        copyPath(screenshot)
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    } label: {
                        Label("Copy Image", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }

                    Divider()

                    Button(role: .destructive) {
                        deleteScreenshot(screenshot)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }
    }

    // MARK: - Actions

    private func copyPath(_ screenshot: BrowserScreenshot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(screenshot.filePath, forType: .string)

        withAnimation(.easeIn(duration: 0.15)) {
            copiedScreenshotId = screenshot.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.2)) {
                if copiedScreenshotId == screenshot.id {
                    copiedScreenshotId = nil
                }
            }
        }
    }

    private func deleteScreenshot(_ screenshot: BrowserScreenshot) {
        // Remove file from disk
        try? FileManager.default.removeItem(atPath: screenshot.filePath)

        // Remove from DB
        do {
            _ = try DatabaseService.shared.dbQueue.write { db in
                try screenshot.delete(db)
            }
        } catch {
            print("ScreenshotGalleryStrip: failed to delete screenshot: \(error)")
        }

        loadScreenshots()
        NotificationCenter.default.post(name: .screenshotsDidChange, object: nil)
    }

    private func loadScreenshots() {
        do {
            screenshots = try DatabaseService.shared.dbQueue.read { db in
                try BrowserScreenshot
                    .filter(Column("projectId") == projectId)
                    .order(Column("createdAt").desc)
                    .limit(20)
                    .fetchAll(db)
            }
        } catch {
            print("ScreenshotGalleryStrip: failed to load screenshots: \(error)")
        }
    }
}

extension Notification.Name {
    static let screenshotsDidChange = Notification.Name("screenshotsDidChange")
}
