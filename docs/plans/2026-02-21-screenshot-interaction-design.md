# Screenshot Thumbnail Interactions

## Problem

Browser screenshots save to a gallery strip but are non-interactive. Users need to use screenshots in their active Claude sessions (paste the path into the terminal), but there's no way to get the path from the gallery to the terminal.

## Design

Three interaction modes on `ScreenshotGalleryStrip` thumbnails, all in a single file change:

### 1. Single-click: Copy path to clipboard

- Click thumbnail → copy file path as string to system clipboard
- Brief "Copied!" overlay fades in on the thumbnail (0.8s duration)
- User Cmd+V's into terminal → path is pasted as text

### 2. Drag: File URL provider

- Thumbnails are draggable via `.onDrag` providing `NSItemProvider` with `.fileURL`
- Terminal already accepts `.fileURL` drops (in `FocusableTerminalView.performDragOperation`)
- Shell-escapes the path and sends it to the active shell process

### 3. Right-click: Context menu

Menu items:
- **Copy Path** — copies file path string to clipboard
- **Copy Image** — copies `NSImage` to clipboard
- **Reveal in Finder** — `NSWorkspace.shared.activateFileViewerSelecting([url])`
- **Delete** — removes from DB + deletes file from disk

## Scope

**One file modified:** `ScreenshotGalleryStrip.swift`

No changes needed to the terminal — it already handles file URL drops and text paste.

## Implementation Notes

- Use `.onDrag` modifier with `NSItemProvider(contentsOf: URL(fileURLWithPath: filePath))`
- Use `.contextMenu` for the right-click menu
- "Copied!" overlay uses `@State` boolean with `DispatchQueue.main.asyncAfter` to auto-dismiss
- Delete confirmation via `.confirmationDialog` or just do it directly (screenshots are easily retaken)
