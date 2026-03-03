import SwiftUI
import GRDB
import AppKit

struct ImageStudioView: View {
    @EnvironmentObject var appState: AppState

    @State private var prompt = ""
    @State private var selectedAspectRatio = "1:1"
    @State private var selectedSize = "1K"
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var generations: [GeneratedImage] = []
    @State private var selectedImage: GeneratedImage?
    @State private var selectedNSImage: NSImage?
    @State private var isEditing = false
    @State private var editPrompt = ""

    private let service = ImageGenerationService()
    private let aspectRatios = ["1:1", "16:9", "9:16", "4:3", "3:2"]
    private let sizes = ["1K", "2K", "4K"]

    var body: some View {
        HSplitView {
            leftPanel
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            rightPanel
                .frame(minWidth: 400)
        }
        .onAppear { loadGenerations() }
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Prompt")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .frame(minHeight: 80, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ratio").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                        Picker("", selection: $selectedAspectRatio) {
                            ForEach(aspectRatios, id: \.self) { Text($0) }
                        }.labelsHidden().frame(width: 80)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Size").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                        Picker("", selection: $selectedSize) {
                            ForEach(sizes, id: \.self) { Text($0) }
                        }.labelsHidden().frame(width: 70)
                    }
                    Spacer()
                }

                Button(action: generate) {
                    HStack {
                        if isGenerating {
                            ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(isGenerating ? "Generating..." : "Generate")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                .keyboardShortcut(.return, modifiers: .command)

                if let error = errorMessage {
                    Text(error).font(.system(size: 11)).foregroundColor(.red).lineLimit(3)
                }
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("History")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                if generations.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28)).foregroundColor(.secondary)
                        Text("No images yet").font(.system(size: 12)).foregroundColor(.secondary)
                        Text("Enter a prompt and click Generate").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(generations) { gen in
                                historyRow(gen)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func historyRow(_ gen: GeneratedImage) -> some View {
        HStack(spacing: 10) {
            if let nsImage = NSImage(contentsOfFile: gen.filePath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "photo").foregroundColor(.secondary))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(gen.prompt).font(.system(size: 12)).lineLimit(2)
                Text(gen.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(selectedImage?.id == gen.id ? Color.accentColor.opacity(0.15) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedImage = gen
            loadSelectedImage()
        }
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        VStack(spacing: 0) {
            if let selected = selectedImage, let nsImage = selectedNSImage {
                ScrollView {
                    VStack(spacing: 16) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 600)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

                        if let text = selected.responseText, !text.isEmpty {
                            Text(text).font(.system(size: 12)).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                        }

                        if isEditing {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Edit Instructions").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                                TextEditor(text: $editPrompt)
                                    .font(.system(size: 13))
                                    .frame(height: 60)
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                                HStack {
                                    Button("Cancel") { isEditing = false; editPrompt = "" }.buttonStyle(.bordered)
                                    Button(action: editSelectedImage) {
                                        HStack {
                                            if isGenerating { ProgressView().scaleEffect(0.7) }
                                            Text(isGenerating ? "Editing..." : "Apply Edit")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(editPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                                }
                            }
                        }
                    }
                    .padding(20)
                }

                Divider()

                HStack(spacing: 12) {
                    Text(selected.prompt).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: { copyToClipboard(nsImage) }) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }.buttonStyle(.bordered).controlSize(.small)

                    Button(action: { isEditing.toggle() }) {
                        Label("Edit", systemImage: "pencil")
                    }.buttonStyle(.bordered).controlSize(.small)

                    Button(action: { showInFinder(selected.filePath) }) {
                        Label("Reveal", systemImage: "folder")
                    }.buttonStyle(.bordered).controlSize(.small)

                    Button(action: { deleteGeneration(selected) }) {
                        Label("Delete", systemImage: "trash")
                    }.buttonStyle(.bordered).controlSize(.small).tint(.red)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "wand.and.stars").font(.system(size: 40)).foregroundColor(.secondary.opacity(0.5))
                    Text("Image Studio").font(.system(size: 18, weight: .semibold)).foregroundColor(.secondary)
                    Text("Generate images with AI. Try prompts like:").font(.system(size: 12)).foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        examplePrompt("A minimalist app icon with a brain symbol, blue gradient")
                        examplePrompt("Hero illustration of a developer working late, isometric style")
                        examplePrompt("Clean dashboard mockup with charts and cards, dark mode")
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func examplePrompt(_ text: String) -> some View {
        Button(action: { prompt = text }) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 10)).foregroundColor(.accentColor)
                Text(text).font(.system(size: 11)).foregroundColor(.primary).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func generate() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        isGenerating = true
        errorMessage = nil
        let ratio = selectedAspectRatio
        let size = selectedSize
        let projectId = appState.currentProject?.id ?? "__global__"
        let projectPath = appState.currentProject?.path ?? ""

        Task {
            await service.resetConversation()
            let result = await service.generateImage(prompt: trimmedPrompt, aspectRatio: ratio, imageSize: size)
            await MainActor.run {
                isGenerating = false
                if let error = result.error { errorMessage = error; return }
                if let saved = ImageGenerationService.saveGeneration(
                    imageData: result.imageData, prompt: trimmedPrompt, responseText: result.responseText,
                    projectId: projectId, projectPath: projectPath, aspectRatio: ratio, imageSize: size
                ) {
                    generations.insert(saved, at: 0)
                    selectedImage = saved
                    loadSelectedImage()
                    prompt = ""
                }
            }
        }
    }

    private func editSelectedImage() {
        guard let selected = selectedImage,
              let imageData = try? Data(contentsOf: URL(fileURLWithPath: selected.filePath)) else { return }
        let trimmedEdit = editPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEdit.isEmpty else { return }
        isGenerating = true
        errorMessage = nil
        let ratio = selected.aspectRatio
        let size = selected.imageSize
        let projectId = appState.currentProject?.id ?? "__global__"
        let projectPath = appState.currentProject?.path ?? ""

        Task {
            await service.resetConversation()
            let result = await service.editImage(imageData: imageData, prompt: trimmedEdit, aspectRatio: ratio, imageSize: size)
            await MainActor.run {
                isGenerating = false
                if let error = result.error { errorMessage = error; return }
                if let saved = ImageGenerationService.saveGeneration(
                    imageData: result.imageData, prompt: trimmedEdit, responseText: result.responseText,
                    projectId: projectId, projectPath: projectPath, aspectRatio: ratio, imageSize: size, parentImageId: selected.id
                ) {
                    generations.insert(saved, at: 0)
                    selectedImage = saved
                    loadSelectedImage()
                    isEditing = false
                    editPrompt = ""
                }
            }
        }
    }

    private func loadGenerations() {
        guard let projectId = appState.currentProject?.id else { return }
        do {
            generations = try DatabaseService.shared.dbQueue.read { db in
                try GeneratedImage
                    .filter(Column("projectId") == projectId)
                    .order(Column("createdAt").desc)
                    .fetchAll(db)
            }
            if selectedImage == nil, let first = generations.first {
                selectedImage = first
                loadSelectedImage()
            }
        } catch {
            print("ImageStudioView: failed to load generations: \(error)")
        }
    }

    private func loadSelectedImage() {
        guard let selected = selectedImage else { selectedNSImage = nil; return }
        selectedNSImage = NSImage(contentsOfFile: selected.filePath)
    }

    private func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func showInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    private func deleteGeneration(_ gen: GeneratedImage) {
        try? FileManager.default.removeItem(atPath: gen.filePath)
        do {
            _ = try DatabaseService.shared.dbQueue.write { db in try gen.delete(db) }
        } catch {
            print("ImageStudioView: failed to delete: \(error)")
        }
        generations.removeAll { $0.id == gen.id }
        if selectedImage?.id == gen.id {
            selectedImage = generations.first
            loadSelectedImage()
        }
    }
}
