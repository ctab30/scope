# Image Studio Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a full image generation workspace (Image Studio) to the Context app, powered by Google Gemini 3.1 Flash Image Preview via OpenRouter. Supports text-to-image, image editing, multi-turn iteration, and MCP integration.

**Architecture:** Three layers — `ImageGenerationService` (OpenRouter HTTP client), database model (`generatedImages` table via GRDB), and two UI surfaces (Images tab in GUI + 4 MCP tools). Follows existing patterns: `EmbeddingClient.swift` for HTTP, `DatabaseService.swift` for migrations, `ScopeMCP/main.swift` for tool definitions.

**Tech Stack:** Swift, SwiftUI, GRDB, OpenRouter API, MCP (stdio JSON-RPC)

**Design Doc:** `docs/plans/2026-02-27-image-studio-design.md`

---

### Task 1: Database Migration & Model

**Files:**
- Create: `Context/Sources/Context/Models/GeneratedImage.swift`
- Modify: `Context/Sources/Context/Services/DatabaseService.swift:361-386` (add v17 migration after v16)

**Step 1: Create the `GeneratedImage` GRDB model**

Create `Context/Sources/Context/Models/GeneratedImage.swift`:

```swift
import Foundation
import GRDB

struct GeneratedImage: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: String
    var prompt: String
    var responseText: String?
    var filePath: String
    var model: String = "google/gemini-3.1-flash-image-preview"
    var aspectRatio: String = "1:1"
    var imageSize: String = "1K"
    var parentImageId: Int64?
    var createdAt: Date

    static let databaseTableName = "generatedImages"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

**Step 2: Add v17 migration to DatabaseService**

In `DatabaseService.swift`, after the `v16_createBriefing` migration block (line ~383), add:

```swift
migrator.registerMigration("v17_createGeneratedImages") { db in
    try db.create(table: "generatedImages") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("projectId", .text).notNull()
            .references("projects", onDelete: .cascade)
        t.column("prompt", .text).notNull()
        t.column("responseText", .text)
        t.column("filePath", .text).notNull()
        t.column("model", .text).notNull()
            .defaults(to: "google/gemini-3.1-flash-image-preview")
        t.column("aspectRatio", .text).defaults(to: "1:1")
        t.column("imageSize", .text).defaults(to: "1K")
        t.column("parentImageId", .integer)
            .references("generatedImages", onDelete: .setNull)
        t.column("createdAt", .datetime).notNull()
    }
}
```

**Step 3: Build to verify migration compiles**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Context/Sources/Context/Models/GeneratedImage.swift Context/Sources/Context/Services/DatabaseService.swift
git commit -m "feat(image-studio): add GeneratedImage model and v17 migration"
```

---

### Task 2: ImageGenerationService

**Files:**
- Create: `Context/Sources/Context/Services/ImageGenerationService.swift`

This service wraps the OpenRouter chat completions API for image generation. Follows the HTTP pattern from `EmbeddingClient.swift` (Bearer auth, JSONSerialization, error handling).

**Step 1: Create the service**

Create `Context/Sources/Context/Services/ImageGenerationService.swift`:

```swift
import Foundation
import GRDB

actor ImageGenerationService {

    struct GenerationResult {
        let imageData: Data
        let responseText: String?
        let error: String?
    }

    private let model = "google/gemini-3.1-flash-image-preview"
    private let endpoint = "https://openrouter.ai/api/v1/chat/completions"

    // Per-session conversation history for multi-turn editing
    private var conversationHistory: [[String: Any]] = []

    /// Generate an image from a text prompt.
    func generateImage(
        prompt: String,
        aspectRatio: String = "1:1",
        imageSize: String = "1K"
    ) async -> GenerationResult {
        let message: [String: Any] = [
            "role": "user",
            "content": [["type": "text", "text": prompt]]
        ]
        conversationHistory.append(message)
        return await callAPI(aspectRatio: aspectRatio, imageSize: imageSize)
    }

    /// Edit an existing image with a text prompt (image-to-image).
    func editImage(
        imageData: Data,
        prompt: String,
        aspectRatio: String = "1:1",
        imageSize: String = "1K"
    ) async -> GenerationResult {
        let base64 = imageData.base64EncodedString()
        let dataURL = "data:image/png;base64,\(base64)"
        let message: [String: Any] = [
            "role": "user",
            "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": dataURL]]
            ]
        ]
        conversationHistory.append(message)
        return await callAPI(aspectRatio: aspectRatio, imageSize: imageSize)
    }

    /// Clear conversation history to start a fresh session.
    func resetConversation() {
        conversationHistory = []
    }

    // MARK: - API Call

    private func callAPI(
        aspectRatio: String,
        imageSize: String
    ) async -> GenerationResult {
        let apiKey = await MainActor.run { ClaudeService.openRouterAPIKey }
        guard let apiKey, !apiKey.isEmpty else {
            return GenerationResult(imageData: Data(), responseText: nil, error: "OpenRouter API key not configured")
        }

        let body: [String: Any] = [
            "model": model,
            "modalities": ["image", "text"],
            "messages": conversationHistory,
            "image_config": [
                "aspect_ratio": aspectRatio,
                "image_size": imageSize
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return GenerationResult(imageData: Data(), responseText: nil, error: "Failed to encode request")
        }

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Context App", forHTTPHeaderField: "X-Title")
        request.httpBody = bodyData
        request.timeoutInterval = 120 // Image generation can be slow

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return GenerationResult(imageData: Data(), responseText: nil, error: "Invalid response")
            }

            guard httpResponse.statusCode == 200 else {
                let raw = String(data: data, encoding: .utf8) ?? "Unknown"
                return GenerationResult(imageData: Data(), responseText: nil, error: "HTTP \(httpResponse.statusCode): \(String(raw.prefix(300)))")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return GenerationResult(imageData: Data(), responseText: nil, error: "Invalid JSON response")
            }

            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return GenerationResult(imageData: Data(), responseText: nil, error: message)
            }

            // Parse response: extract image data and optional text
            guard let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                return GenerationResult(imageData: Data(), responseText: nil, error: "Unexpected response format")
            }

            // Append assistant message to conversation history for multi-turn
            if let rawContent = message["content"] {
                let assistantMsg: [String: Any] = [
                    "role": "assistant",
                    "content": rawContent
                ]
                conversationHistory.append(assistantMsg)
            }

            var imageData: Data?
            var responseText: String?

            for part in content {
                guard let type = part["type"] as? String else { continue }
                if type == "image_url",
                   let imageUrl = part["image_url"] as? [String: Any],
                   let urlString = imageUrl["url"] as? String,
                   let commaIndex = urlString.firstIndex(of: ",") {
                    let base64String = String(urlString[urlString.index(after: commaIndex)...])
                    imageData = Data(base64Encoded: base64String)
                } else if type == "text",
                          let text = part["text"] as? String {
                    responseText = text
                }
            }

            guard let finalImageData = imageData, !finalImageData.isEmpty else {
                return GenerationResult(imageData: Data(), responseText: responseText, error: "No image in response")
            }

            return GenerationResult(imageData: finalImageData, responseText: responseText, error: nil)
        } catch {
            return GenerationResult(imageData: Data(), responseText: nil, error: error.localizedDescription)
        }
    }

    // MARK: - File Management

    /// Save image data to disk and create a DB record. Returns the saved GeneratedImage.
    @MainActor
    static func saveGeneration(
        imageData: Data,
        prompt: String,
        responseText: String?,
        projectId: String,
        projectPath: String,
        aspectRatio: String,
        imageSize: String,
        parentImageId: Int64? = nil
    ) -> GeneratedImage? {
        // Build save directory
        let saveDir: URL
        if projectPath.isEmpty {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("Context/generated-images", isDirectory: true)
            saveDir = appSupport
        } else {
            saveDir = URL(fileURLWithPath: projectPath)
                .appendingPathComponent("assets/generated", isDirectory: true)
        }

        do {
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        } catch {
            print("ImageGenerationService: failed to create directory: \(error)")
            return nil
        }

        // Generate unique filename
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "gen_\(timestamp)_\(UUID().uuidString.prefix(8)).png"
        let filePath = saveDir.appendingPathComponent(filename)

        do {
            try imageData.write(to: filePath)
        } catch {
            print("ImageGenerationService: failed to write image: \(error)")
            return nil
        }

        // Insert DB record
        var image = GeneratedImage(
            projectId: projectId,
            prompt: prompt,
            responseText: responseText,
            filePath: filePath.path,
            aspectRatio: aspectRatio,
            imageSize: imageSize,
            parentImageId: parentImageId,
            createdAt: Date()
        )

        do {
            try DatabaseService.shared.dbQueue.write { db in
                try image.insert(db)
            }
            return image
        } catch {
            print("ImageGenerationService: failed to insert DB record: \(error)")
            return nil
        }
    }
}
```

**Step 2: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Context/Sources/Context/Services/ImageGenerationService.swift
git commit -m "feat(image-studio): add ImageGenerationService with OpenRouter integration"
```

---

### Task 3: ImageStudioView — Main UI

**Files:**
- Create: `Context/Sources/Context/Views/ImageStudio/ImageStudioView.swift`
- Modify: `Context/Sources/Context/ViewModels/AppState.swift:15-43` (add `case images` to GUITab)
- Modify: `Context/Sources/Context/Views/GUIPanelView.swift:150-177` (add `.images` case to switch)

**Step 1: Add `images` case to GUITab enum**

In `AppState.swift`, add `case images = "Images"` to the `GUITab` enum (after `git`), and add the icon mapping:

```swift
case images: return "photo.artframe"
```

**Step 2: Create `ImageStudioView`**

Create `Context/Sources/Context/Views/ImageStudio/ImageStudioView.swift`:

```swift
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
            // Left panel: prompt + history
            leftPanel
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)

            // Right panel: canvas
            rightPanel
                .frame(minWidth: 400)
        }
        .onAppear { loadGenerations() }
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(spacing: 0) {
            // Prompt area
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
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )

                HStack(spacing: 12) {
                    // Aspect ratio picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ratio")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        Picker("", selection: $selectedAspectRatio) {
                            ForEach(aspectRatios, id: \.self) { Text($0) }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                    }

                    // Size picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Size")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        Picker("", selection: $selectedSize) {
                            ForEach(sizes, id: \.self) { Text($0) }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                    }

                    Spacer()
                }

                Button(action: generate) {
                    HStack {
                        if isGenerating {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(isGenerating ? "Generating…" : "Generate")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                .keyboardShortcut(.return, modifiers: .command)

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .lineLimit(3)
                }
            }
            .padding(16)

            Divider()

            // History
            VStack(alignment: .leading, spacing: 6) {
                Text("History")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                if generations.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Text("No images yet")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("Enter a prompt and click Generate")
                            .font(.system(size: 11))
                            .foregroundColor(.tertiary)
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
            // Thumbnail
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
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(gen.prompt)
                    .font(.system(size: 12))
                    .lineLimit(2)
                Text(gen.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selectedImage?.id == gen.id ? Color.accentColor.opacity(0.15) : Color.clear)
        )
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
                // Image display
                ScrollView {
                    VStack(spacing: 16) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 600)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

                        if let text = selected.responseText, !text.isEmpty {
                            Text(text)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }

                        // Edit mode
                        if isEditing {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Edit Instructions")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)

                                TextEditor(text: $editPrompt)
                                    .font(.system(size: 13))
                                    .frame(height: 60)
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                    )

                                HStack {
                                    Button("Cancel") { isEditing = false; editPrompt = "" }
                                        .buttonStyle(.bordered)
                                    Button(action: editSelectedImage) {
                                        HStack {
                                            if isGenerating {
                                                ProgressView().scaleEffect(0.7)
                                            }
                                            Text(isGenerating ? "Editing…" : "Apply Edit")
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

                // Action bar
                HStack(spacing: 12) {
                    Text(selected.prompt)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: { copyToClipboard(nsImage) }) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: { isEditing.toggle() }) {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: { showInFinder(selected.filePath) }) {
                        Label("Reveal", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: { deleteGeneration(selected) }) {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                // Empty state
                VStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Image Studio")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("Generate images with AI. Try prompts like:")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

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
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
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
            let result = await service.generateImage(
                prompt: trimmedPrompt,
                aspectRatio: ratio,
                imageSize: size
            )

            await MainActor.run {
                isGenerating = false

                if let error = result.error {
                    errorMessage = error
                    return
                }

                if let saved = ImageGenerationService.saveGeneration(
                    imageData: result.imageData,
                    prompt: trimmedPrompt,
                    responseText: result.responseText,
                    projectId: projectId,
                    projectPath: projectPath,
                    aspectRatio: ratio,
                    imageSize: size
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
            let result = await service.editImage(
                imageData: imageData,
                prompt: trimmedEdit,
                aspectRatio: ratio,
                imageSize: size
            )

            await MainActor.run {
                isGenerating = false

                if let error = result.error {
                    errorMessage = error
                    return
                }

                if let saved = ImageGenerationService.saveGeneration(
                    imageData: result.imageData,
                    prompt: trimmedEdit,
                    responseText: result.responseText,
                    projectId: projectId,
                    projectPath: projectPath,
                    aspectRatio: ratio,
                    imageSize: size,
                    parentImageId: selected.id
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
        guard let selected = selectedImage else {
            selectedNSImage = nil
            return
        }
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
        // Remove file
        try? FileManager.default.removeItem(atPath: gen.filePath)
        // Remove DB record
        do {
            _ = try DatabaseService.shared.dbQueue.write { db in
                try gen.delete(db)
            }
        } catch {
            print("ImageStudioView: failed to delete: \(error)")
        }
        // Update UI
        generations.removeAll { $0.id == gen.id }
        if selectedImage?.id == gen.id {
            selectedImage = generations.first
            loadSelectedImage()
        }
    }
}
```

**Step 3: Wire into GUIPanelView**

In `GUIPanelView.swift`, add this case inside the `switch appState.selectedTab` block (around line 170, before `case .browser`):

```swift
case .images:
    ImageStudioView()
```

**Step 4: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add Context/Sources/Context/Views/ImageStudio/ImageStudioView.swift \
        Context/Sources/Context/ViewModels/AppState.swift \
        Context/Sources/Context/Views/GUIPanelView.swift
git commit -m "feat(image-studio): add ImageStudioView UI with prompt, gallery, canvas, and edit mode"
```

---

### Task 4: MCP Tools — Image Generation via Claude Code

**Files:**
- Modify: `Context/Sources/ScopeMCP/main.swift` — add 4 tool definitions to `toolsList()` and 4 handlers to `handleToolCall()`

**Step 1: Add tool definitions to `toolsList()`**

Find the tools list array (in the `toolsList()` function) and add these 4 entries before the closing bracket:

```swift
[
    "name": "generate_image",
    "description": "Generate an image from a text prompt using AI (Gemini 3.1 Flash). Returns the file path of the generated image. The image is saved to the project's assets/generated/ directory.",
    "inputSchema": [
        "type": "object",
        "properties": [
            "prompt": ["type": "string", "description": "Text description of the image to generate"],
            "aspect_ratio": ["type": "string", "description": "Aspect ratio: 1:1, 16:9, 9:16, 4:3, 3:2 (default: 1:1)"],
            "size": ["type": "string", "description": "Resolution: 1K, 2K, 4K (default: 1K)"],
            "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"],
        ],
        "required": ["prompt"]
    ]
],
[
    "name": "edit_image",
    "description": "Edit an existing image with text instructions using AI. Provide the file path of the source image and editing instructions. Returns the file path of the edited image.",
    "inputSchema": [
        "type": "object",
        "properties": [
            "image_path": ["type": "string", "description": "Absolute file path of the image to edit"],
            "prompt": ["type": "string", "description": "Editing instructions (e.g. 'make the background blue', 'add a shadow')"],
            "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"],
        ],
        "required": ["image_path", "prompt"]
    ]
],
[
    "name": "list_images",
    "description": "List generated images for a project, ordered by most recent first.",
    "inputSchema": [
        "type": "object",
        "properties": [
            "project_id": ["type": "string", "description": "Project ID (auto-detected if omitted)"],
            "limit": ["type": "integer", "description": "Max results (default: 20)"],
            "offset": ["type": "integer", "description": "Skip first N results (default: 0)"],
        ],
        "required": []
    ]
],
[
    "name": "get_image",
    "description": "Get details of a specific generated image by ID, including prompt, file path, model, and metadata.",
    "inputSchema": [
        "type": "object",
        "properties": [
            "image_id": ["type": "integer", "description": "Image ID"]
        ],
        "required": ["image_id"]
    ]
]
```

**Step 2: Add tool handlers to `handleToolCall()`**

In the `switch toolName` block, add before `default:`:

```swift
case "generate_image":  result = try generateImage(args)
case "edit_image":      result = try editImage(args)
case "list_images":     result = try listImages(args)
case "get_image":       result = try getImage(args)
```

**Step 3: Implement the 4 handler functions**

Add these functions to the MCP server class (after existing handler functions):

```swift
// MARK: - Image Generation Tools

private func generateImage(_ args: [String: Any]) throws -> String {
    guard let prompt = args["prompt"] as? String else {
        throw MCPError(message: "prompt is required")
    }
    let aspectRatio = args["aspect_ratio"] as? String ?? "1:1"
    let size = args["size"] as? String ?? "1K"
    let projectId = resolveProjectId(args)
    let projectPath = resolveProjectPath(projectId)

    // Synchronous wrapper for async image generation
    let semaphore = DispatchSemaphore(value: 0)
    var generationResult: ImageGenerationService.GenerationResult?

    let service = ImageGenerationService()
    Task {
        generationResult = await service.generateImage(
            prompt: prompt,
            aspectRatio: aspectRatio,
            imageSize: size
        )
        semaphore.signal()
    }
    semaphore.wait()

    guard let result = generationResult else {
        throw MCPError(message: "Generation failed: no result")
    }
    if let error = result.error {
        throw MCPError(message: "Generation failed: \(error)")
    }

    // Save to disk
    let saveDir: URL
    if projectPath.isEmpty {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Context/generated-images", isDirectory: true)
        saveDir = appSupport
    } else {
        saveDir = URL(fileURLWithPath: projectPath)
            .appendingPathComponent("assets/generated", isDirectory: true)
    }
    try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)

    let timestamp = Int(Date().timeIntervalSince1970)
    let filename = "gen_\(timestamp)_\(UUID().uuidString.prefix(8)).png"
    let filePath = saveDir.appendingPathComponent(filename)
    try result.imageData.write(to: filePath)

    // Insert DB record
    try db.write { conn in
        try conn.execute(sql: """
            INSERT INTO generatedImages (projectId, prompt, responseText, filePath, model, aspectRatio, imageSize, createdAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            projectId, prompt, result.responseText, filePath.path,
            "google/gemini-3.1-flash-image-preview", aspectRatio, size, Date()
        ])
    }

    let response: [String: Any] = [
        "file_path": filePath.path,
        "prompt": prompt,
        "aspect_ratio": aspectRatio,
        "size": size,
        "response_text": result.responseText ?? ""
    ]
    return String(data: try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted), encoding: .utf8) ?? "{}"
}

private func editImage(_ args: [String: Any]) throws -> String {
    guard let imagePath = args["image_path"] as? String else {
        throw MCPError(message: "image_path is required")
    }
    guard let prompt = args["prompt"] as? String else {
        throw MCPError(message: "prompt is required")
    }
    guard FileManager.default.fileExists(atPath: imagePath) else {
        throw MCPError(message: "Image not found at: \(imagePath)")
    }
    guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else {
        throw MCPError(message: "Failed to read image at: \(imagePath)")
    }

    let projectId = resolveProjectId(args)
    let projectPath = resolveProjectPath(projectId)

    let semaphore = DispatchSemaphore(value: 0)
    var generationResult: ImageGenerationService.GenerationResult?

    let service = ImageGenerationService()
    Task {
        generationResult = await service.editImage(
            imageData: imageData,
            prompt: prompt
        )
        semaphore.signal()
    }
    semaphore.wait()

    guard let result = generationResult else {
        throw MCPError(message: "Edit failed: no result")
    }
    if let error = result.error {
        throw MCPError(message: "Edit failed: \(error)")
    }

    // Save edited image
    let saveDir: URL
    if projectPath.isEmpty {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Context/generated-images", isDirectory: true)
        saveDir = appSupport
    } else {
        saveDir = URL(fileURLWithPath: projectPath)
            .appendingPathComponent("assets/generated", isDirectory: true)
    }
    try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)

    let timestamp = Int(Date().timeIntervalSince1970)
    let filename = "edit_\(timestamp)_\(UUID().uuidString.prefix(8)).png"
    let filePath = saveDir.appendingPathComponent(filename)
    try result.imageData.write(to: filePath)

    // Find parent image ID if source was a generated image
    let parentId = try db.read { conn -> Int64? in
        try Int64.fetchOne(conn, sql: "SELECT id FROM generatedImages WHERE filePath = ?", arguments: [imagePath])
    }

    try db.write { conn in
        try conn.execute(sql: """
            INSERT INTO generatedImages (projectId, prompt, responseText, filePath, model, aspectRatio, imageSize, parentImageId, createdAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            projectId, prompt, result.responseText, filePath.path,
            "google/gemini-3.1-flash-image-preview", "1:1", "1K", parentId, Date()
        ])
    }

    let response: [String: Any] = [
        "file_path": filePath.path,
        "prompt": prompt,
        "source_image": imagePath,
        "response_text": result.responseText ?? ""
    ]
    return String(data: try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted), encoding: .utf8) ?? "{}"
}

private func listImages(_ args: [String: Any]) throws -> String {
    let projectId = resolveProjectId(args)
    let limit = args["limit"] as? Int ?? 20
    let offset = args["offset"] as? Int ?? 0

    let rows = try db.read { conn in
        try Row.fetchAll(conn, sql: """
            SELECT id, projectId, prompt, responseText, filePath, model, aspectRatio, imageSize, parentImageId, createdAt
            FROM generatedImages
            WHERE projectId = ?
            ORDER BY createdAt DESC
            LIMIT ? OFFSET ?
        """, arguments: [projectId, limit, offset])
    }

    let images: [[String: Any]] = rows.map { row in
        [
            "id": row["id"] as Any,
            "prompt": row["prompt"] as Any,
            "file_path": row["filePath"] as Any,
            "aspect_ratio": row["aspectRatio"] as Any,
            "size": row["imageSize"] as Any,
            "parent_image_id": row["parentImageId"] as Any,
            "created_at": (row["createdAt"] as? Date)?.ISO8601Format() ?? ""
        ]
    }

    return String(data: try JSONSerialization.data(withJSONObject: images, options: .prettyPrinted), encoding: .utf8) ?? "[]"
}

private func getImage(_ args: [String: Any]) throws -> String {
    guard let imageId = args["image_id"] as? Int64 ?? (args["image_id"] as? Int).map({ Int64($0) }) else {
        throw MCPError(message: "image_id is required")
    }

    guard let row = try db.read({ conn in
        try Row.fetchOne(conn, sql: "SELECT * FROM generatedImages WHERE id = ?", arguments: [imageId])
    }) else {
        throw MCPError(message: "Image not found with id: \(imageId)")
    }

    let image: [String: Any] = [
        "id": row["id"] as Any,
        "project_id": row["projectId"] as Any,
        "prompt": row["prompt"] as Any,
        "response_text": row["responseText"] as Any,
        "file_path": row["filePath"] as Any,
        "model": row["model"] as Any,
        "aspect_ratio": row["aspectRatio"] as Any,
        "size": row["imageSize"] as Any,
        "parent_image_id": row["parentImageId"] as Any,
        "created_at": (row["createdAt"] as? Date)?.ISO8601Format() ?? ""
    ]

    return String(data: try JSONSerialization.data(withJSONObject: image, options: .prettyPrinted), encoding: .utf8) ?? "{}"
}

private func resolveProjectPath(_ projectId: String) -> String {
    (try? db.read { conn in
        try String.fetchOne(conn, sql: "SELECT path FROM projects WHERE id = ?", arguments: [projectId])
    }) ?? ""
}
```

**Step 4: Import ImageGenerationService in MCP target**

The MCP binary is a separate target. The `ImageGenerationService` lives in the main Context module. Since the MCP binary may not have access to the Context module directly, the service code should be accessible. Check the Package.swift to see if ScopeMCP depends on the Context library. If not, the MCP handlers should create the service inline or the service file needs to be in a shared location.

**Practical approach:** If the MCP target can't import the Context module, duplicate the HTTP call logic directly in the MCP handler functions (the `callAPI` portion is ~40 lines). The MCP is a standalone binary and needs to be self-contained.

Check: `grep -A5 "ScopeMCP" Context/Package.swift` to see dependencies. If ScopeMCP doesn't depend on Context, inline the HTTP call in the MCP handlers.

**Step 5: Build to verify**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1 | tail -10`
Expected: Build succeeds

**Step 6: Commit**

```bash
git add Context/Sources/ScopeMCP/main.swift
git commit -m "feat(image-studio): add MCP tools — generate_image, edit_image, list_images, get_image"
```

---

### Task 5: End-to-End Testing & Polish

**Files:**
- Potentially fix: any build errors from Tasks 1-4
- Verify: all 4 MCP tools respond correctly

**Step 1: Build and fix any compilation errors**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build 2>&1`

Fix any errors that arise — common issues:
- Missing imports (Foundation, GRDB, AppKit)
- MCP target missing access to `ImageGenerationService` (if separate module)
- `Column` usage needs `import GRDB`
- Actor isolation issues with `ImageGenerationService` (may need `nonisolated` for static methods)

**Step 2: Launch app and verify UI**

Run: `cd /Users/connor/Documents/claude-code-projects/scope/Context && swift build && open .build/debug/Scope.app`

Verify:
- Images tab appears in tab bar with photo.artframe icon
- Empty state shows with example prompts
- Entering a prompt and clicking Generate produces an image
- Generated image appears in history and canvas
- Edit mode works (overlay prompt + apply)
- Copy to clipboard, Reveal in Finder, Delete all work

**Step 3: Test MCP tools**

Test via the MCP binary directly or through Claude Code:
- `generate_image` with a simple prompt
- `list_images` to see the generation
- `get_image` with the returned ID
- `edit_image` with the file path and edit instructions

**Step 4: Final commit**

```bash
git add -A
git commit -m "feat(image-studio): polish and fixes from end-to-end testing"
```

---

## Notes for Implementer

**Key patterns to follow:**
- **HTTP client:** Follow `EmbeddingClient.swift` — `URLRequest`, Bearer auth, `JSONSerialization`, error handling
- **Database model:** Follow `Note.swift` — `Codable, Identifiable, FetchableRecord, MutablePersistableRecord` with `didInsert`
- **Migration:** Follow `v16_createBriefing` — `migrator.registerMigration("v17_...")` after the last existing migration
- **MCP tools:** Follow `create_note` pattern — tool definition in `toolsList()`, case in `handleToolCall()`, handler function
- **Tab:** `GUITab` is `CaseIterable` so adding a case auto-adds it to the tab bar. Just add the icon mapping and the switch case in `GUIPanelView`

**OpenRouter API key:** Accessed via `ClaudeService.openRouterAPIKey` (UserDefaults). Already used by `EmbeddingClient`.

**Image response format:** The Gemini model returns base64 data URLs in the content array: `data:image/png;base64,...`. Parse by finding the comma separator and base64-decoding everything after it.

**Timeout:** Image generation takes 10-30s typically. Use 120s timeout on the URLRequest.
