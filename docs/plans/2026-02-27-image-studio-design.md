# Image Studio Design

## Goal

Add a full image generation workspace to the Context app, powered by Google Gemini 3.1 Flash Image Preview via OpenRouter. Supports text-to-image, image editing, multi-turn iteration, and full MCP integration for Claude Code access.

## Architecture

Three layers:

1. **ImageGenerationService** — HTTP client for OpenRouter's chat completions endpoint with `modalities: ["image", "text"]`. Handles text-to-image, image-to-image editing, and multi-turn conversations. Stores conversation history per session for iterative refinement.

2. **Database model** (`generatedImages` table) — Tracks every generation: prompt, response text, file path, model, aspect ratio, resolution, parent image ID (for edits), creation timestamp. Scoped per project.

3. **Two UI surfaces:**
   - **Images tab** in the GUI — full studio with prompt bar, generation gallery, image detail/editing
   - **MCP tools** — `generate_image`, `edit_image`, `list_images`, `get_image`

## Model Details

- **Model:** `google/gemini-3.1-flash-image-preview` (Nano Banana 2)
- **Endpoint:** `POST https://openrouter.ai/api/v1/chat/completions`
- **Cost:** ~$0.08 per generated image
- **Capabilities:** text-to-image, image editing, inpainting, style transfer, multi-turn iteration, text rendering, up to 4K resolution
- **API key:** Reuses existing OpenRouter key from `ClaudeService.openRouterAPIKey` (UserDefaults)

## Request/Response Format

**Text-to-image:**
```json
{
  "model": "google/gemini-3.1-flash-image-preview",
  "modalities": ["image", "text"],
  "messages": [{"role": "user", "content": [{"type": "text", "text": "prompt"}]}],
  "image_config": {"aspect_ratio": "16:9", "image_size": "1K"}
}
```

**Image-to-image editing:**
```json
{
  "messages": [{
    "role": "user",
    "content": [
      {"type": "text", "text": "editing instructions"},
      {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}
    ]
  }]
}
```

**Response:** Images returned as base64 data URLs in `choices[0].message.content` array with `type: "image_url"`.

## UI Layout — Images Tab

**Left panel (prompt + history):**
- Multi-line text input for prompts
- Aspect ratio picker: 1:1, 16:9, 9:16, 4:3, 3:2
- Resolution picker: 1K (default), 2K, 4K
- "Generate" button with loading state
- Scrollable history of past generations (thumbnail + prompt snippet)

**Right panel (canvas):**
- Large image display of selected/latest generation
- AI text response (if any) below the image
- Action bar: Save to Project, Copy to Clipboard, Edit (re-prompt), Delete
- Edit mode: source image with overlay prompt input

**Empty state:** Centered prompt with example suggestions

## MCP Tools

| Tool | Purpose | Key params |
|------|---------|------------|
| `generate_image` | Text-to-image | `prompt`, `aspect_ratio?`, `size?`, `save_to?` |
| `edit_image` | Image + instructions | `image_path`, `prompt`, `save_to?` |
| `list_images` | Browse generations | `limit?`, `offset?` |
| `get_image` | Get generation details | `image_id` |

Default save location: `<projectPath>/assets/generated/`

## Database Schema

```sql
CREATE TABLE generatedImages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    projectId TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    prompt TEXT NOT NULL,
    responseText TEXT,
    filePath TEXT NOT NULL,
    model TEXT NOT NULL DEFAULT 'google/gemini-3.1-flash-image-preview',
    aspectRatio TEXT DEFAULT '1:1',
    imageSize TEXT DEFAULT '1K',
    parentImageId INTEGER REFERENCES generatedImages(id),
    createdAt DATETIME NOT NULL
);
```

## Data Flow

```
User prompt → ImageGenerationService → OpenRouter API
                                            ↓
                                       base64 response
                                            ↓
                                  Decode → Save to disk → Insert DB record
                                            ↓
                                  Return file path + display in UI
```

For edits: source image loaded from disk → base64 encoded → sent with new prompt in conversation thread.
