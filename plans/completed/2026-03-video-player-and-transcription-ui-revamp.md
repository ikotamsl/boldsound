# Video Player & Transcription UI Revamp

> Status: **COMPLETED** - 2026-03-29

## Overview

Add embedded YouTube video playback (HLS streaming via yt-dlp + AVPlayer) and revamp the transcription UI into three tiers: a polished home page with thumbnail cards, a split-pane detail view (video + transcript/summary/chat tabs), and a full library view for browsing history.

**Key architectural choices:**

1. **HLS streaming for YouTube** — Video is streamed, not downloaded locally. yt-dlp extracts a streaming manifest URL at playback time, AVPlayer handles adaptive bitrate. Zero storage cost, fast downloads (still audio-only for transcription), and video is a bonus layer. If offline, the video panel shows "unavailable offline" gracefully.

2. **Two playback modes** — The detail view automatically adapts based on source type:
   - **Video mode** (YouTube + local video files): 40/60 split-pane with video player left, tabbed content right.
   - **Audio mode** (local audio files): Full-width content with a thin persistent audio scrubber bar at the top. Play/pause, waveform scrubber, timestamp, volume — all in one horizontal strip. All vertical and horizontal space goes to the transcript/summary/chat tabs. Same synced highlighting and clickable timestamps as video mode.

   Mode is determined automatically: if `sourceURL` is YouTube or file is a video format → video mode. Otherwise → audio mode. Collapsing the video panel in video mode effectively switches to audio mode layout.

## Design References

Three mockup screenshots define the target UX:

1. **Detail View** — Split-pane: video player (40%) left with controls + title, tabbed content (60%) right with Transcript/Summary/Chat. Transcript shows speaker-labeled segments with timestamps and active-segment highlighting synced to video playback. Chat has clickable timestamp chips that seek the video.

2. **Home Page** — Two input cards side-by-side (YouTube URL + Local File), "Recently Transcribed" section below with thumbnail cards showing title, date, duration badge, and source type.

3. **Library View** — Grid of transcription cards with thumbnails, duration overlays, status badges (AI ANALYZED, SUMMARY), date labels, and favorites (star). Filterable by source type and searchable.

## Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Video storage | Stream only (HLS) | Zero storage cost, download stays audio-only |
| Video player ratio | 40/60 default | Content is primary value, video is reference |
| Playback modes | Auto video/audio | YouTube + video files → split-pane; audio files → full-width + scrubber bar |
| Tags | Skip for now | Adds complexity without clear value in v1 |
| Channel grouping | Skip for now | Not enough value for the implementation cost |
| "Insights found" | Skip | UI bloat from mockup |
| Local file thumbnails | FFmpeg frame extraction for video, placeholder art for audio | Simple and covers both cases |
| Thumbnail storage | Download YouTube thumbnails to local cache dir | Survives offline, fast loading |

## Current State (Pre-Implementation)

### What Exists
- `TranscriptResultView.swift` — Already has Transcript/Summary/Chat tabs with enum-driven switching
- `TranscribeView.swift` — Portal drop zone + YouTube URL card + recent transcription list
- `YouTubeDownloader.swift` — Downloads audio-only, extracts title + duration from yt-dlp metadata (channel, thumbnail, uploader discarded)
- `Transcription` model — Has `sourceURL` for YouTube but no `channelName`, `thumbnailURL`, or video metadata
- No AVPlayer/AVKit usage anywhere in codebase
- DesignSystem tokens established for colors, spacing, typography, layout

### Key Files

| File | Role | Lines |
|------|------|-------|
| `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift` | Detail view with tabs | ~1400 |
| `Sources/MacParakeet/Views/Transcription/TranscribeView.swift` | Home page with inputs + recent list | ~860 |
| `Sources/MacParakeet/Views/MainWindowView.swift` | Sidebar + routing | ~150 |
| `Sources/MacParakeetCore/Models/Transcription.swift` | Data model | ~163 |
| `Sources/MacParakeetCore/Services/YouTubeDownloader.swift` | yt-dlp integration | ~200 |
| `Sources/MacParakeetCore/Database/DatabaseManager.swift` | Migrations | ~500+ |
| `Sources/MacParakeetViewModels/TranscriptionViewModel.swift` | ViewModel for transcription UI | ~500+ |

---

## Phase 1: Foundation — Data Model & YouTube Metadata

**Goal:** Expand the data model and yt-dlp extraction so we have the metadata needed for thumbnails, video playback, and richer UI.

### Step 1.1: Expand Transcription Model

**File:** `Sources/MacParakeetCore/Models/Transcription.swift`

Add fields:

```swift
public var thumbnailURL: String?      // YouTube thumbnail URL (or local cached path)
public var channelName: String?       // YouTube channel name
public var videoDescription: String?  // YouTube video description (useful for LLM context)
```

These are all optional — existing transcriptions continue to work unchanged.

### Step 1.2: Database Migration

**File:** `Sources/MacParakeetCore/Database/DatabaseManager.swift`

Add migration following the existing inline pattern:

```swift
migrator.registerMigration("v0.5-transcription-video-metadata") { db in
    try db.alter(table: "transcriptions") { t in
        t.add(column: "thumbnailURL", .text)
        t.add(column: "channelName", .text)
        t.add(column: "videoDescription", .text)
    }
}
```

### Step 1.3: Expand yt-dlp Metadata Extraction

**File:** `Sources/MacParakeetCore/Services/YouTubeDownloader.swift`

In the `fetchMetadata` / JSON parsing section, extract additional fields:

```swift
let channel = json["channel"] as? String ?? json["uploader"] as? String
let thumbnail = json["thumbnail"] as? String
let description = json["description"] as? String
```

Update `DownloadResult` struct:

```swift
public struct DownloadResult: Sendable {
    public let audioFileURL: URL
    public let title: String
    public let durationSeconds: Int?
    public let channelName: String?       // NEW
    public let thumbnailURL: String?      // NEW
    public let videoDescription: String?  // NEW
}
```

### Step 1.4: Store Metadata in Transcription

**File:** `Sources/MacParakeetCore/Services/TranscriptionService.swift` (or wherever Transcription records are created from DownloadResult)

When creating a Transcription from a YouTube download, populate the new fields:

```swift
transcription.channelName = downloadResult.channelName
transcription.thumbnailURL = downloadResult.thumbnailURL
transcription.videoDescription = downloadResult.videoDescription
```

### Step 1.5: Thumbnail Cache Service

**New file:** `Sources/MacParakeetCore/Services/ThumbnailCacheService.swift`

Simple image downloader that:
- Downloads YouTube thumbnail from URL to `~/Library/Application Support/MacParakeet/thumbnails/{transcriptionId}.jpg`
- Returns local file URL for display
- Checks cache before downloading
- For local video files: uses FFmpeg to extract first frame (`ffmpeg -i input.mp4 -vframes 1 -f image2 output.jpg`)
- For local audio files: returns nil (UI uses placeholder)

```swift
public final class ThumbnailCacheService: Sendable {
    func cachedThumbnail(for transcriptionId: UUID) -> URL?
    func downloadThumbnail(from urlString: String, for transcriptionId: UUID) async throws -> URL
    func extractVideoFrame(from videoPath: String, for transcriptionId: UUID) async throws -> URL
}
```

### Step 1.6: Tests

- Test migration adds columns without breaking existing data
- Test DownloadResult populates new fields from mock yt-dlp JSON
- Test ThumbnailCacheService caches and retrieves correctly
- Test Transcription model encodes/decodes with new optional fields

---

## Phase 2: Media Player Components

**Goal:** Build two playback components — a video player (AVPlayer + HLS for YouTube, local file for video files) and a compact audio scrubber bar (for audio-only files). Both share a common ViewModel that publishes `currentTimeMs` for transcript sync.

### Step 2.1: HLS URL Extraction Service

**New file:** `Sources/MacParakeetCore/Services/VideoStreamService.swift`

Extracts a streaming HLS manifest URL from a YouTube URL using yt-dlp:

```swift
public final class VideoStreamService: Sendable {
    /// Extract HLS streaming URL for a YouTube video.
    /// URLs expire after a few hours — cache per session, re-extract as needed.
    func extractStreamURL(from youtubeURL: String) async throws -> URL

    /// Cache of extracted URLs keyed by video ID, with expiry timestamps.
    /// Automatically re-extracts if expired.
    func streamURL(for videoID: String, sourceURL: String) async throws -> URL
}
```

yt-dlp command: `yt-dlp -f best --get-url "URL"` (returns direct URL that AVPlayer can handle — HLS or progressive).

Implementation notes:
- Cache URLs in memory with ~2hr TTL (they expire on YouTube's end)
- If extraction fails (offline, URL expired), return a clear error the UI can handle
- Run yt-dlp on a background queue — never block UI

### Step 2.2: AVPlayer SwiftUI Wrapper

**New file:** `Sources/MacParakeet/Views/Components/VideoPlayerView.swift`

NSViewRepresentable wrapping AVPlayerView from AVKit:

```swift
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var showsControls: Bool = true

    func makeNSView(context: Context) -> AVPlayerView { ... }
    func updateNSView(_ nsView: AVPlayerView, context: Context) { ... }
}
```

Key behaviors:
- AVPlayerView with `.inline` controlsStyle for the full player
- `.minimal` controlsStyle for mini mode
- Responds to external seek commands (from transcript timestamp clicks)
- Publishes current playback time for transcript sync

### Step 2.3: Video Player ViewModel

**New file:** `Sources/MacParakeetViewModels/VideoPlayerViewModel.swift`

```swift
@MainActor @Observable
public final class VideoPlayerViewModel {
    // State
    public var player: AVPlayer?
    public var isLoading: Bool = false
    public var isPlaying: Bool = false
    public var currentTimeMs: Int = 0
    public var durationMs: Int = 0
    public var error: String?
    public var playerState: PlayerState = .idle  // .idle, .loading, .ready, .error, .unavailableOffline

    // Actions
    public func loadStream(sourceURL: String) async { ... }
    public func seek(toMs: Int) { ... }
    public func togglePlayPause() { ... }
    public func cleanup() { ... }
}

enum PlayerState {
    case idle
    case loading
    case ready
    case error(String)
    case unavailableOffline
}
```

Responsibilities:
- For YouTube: Call VideoStreamService to get HLS URL, create AVPlayer with it
- For local video files: Create AVPlayer directly with the file URL
- For local audio files: Create AVPlayer with the audio file URL (same player, different UI)
- Observe playback time via `addPeriodicTimeObserver` — publish `currentTimeMs` for transcript sync
- Handle errors gracefully (offline, URL extraction failed)
- Clean up player on deinit

The ViewModel is source-agnostic — it always produces an AVPlayer + currentTimeMs. The VIEW layer decides whether to render the video player or the audio scrubber bar.

### Step 2.4: Audio Scrubber Bar Component

**New file:** `Sources/MacParakeet/Views/Components/AudioScrubberBar.swift`

A thin, horizontal bar for audio-only playback. Used when the source is an audio file (no video to show).

```
┌──────────────────────────────────────────────────┐
│  ▶  ━━━━━━━━━●━━━━━━━━━━━━━━  04:12 / 10:00  🔊 │
└──────────────────────────────────────────────────┘
```

Components:
- Play/pause toggle button (left)
- Waveform or linear scrubber (center, fills available width)
- Current time / total duration label (right of scrubber)
- Volume control (far right, optional)
- Fixed height: ~44px (compact, doesn't eat into content space)
- Binds to the same `MediaPlayerViewModel` as the video player
- Tap/drag on scrubber calls `viewModel.seek(toMs:)`
- Accent color for the progress fill, muted for the track

This bar sits at the top of the detail view content area, pinned above the tab bar. The full width below it is available for Transcript/Summary/Chat content.

### Step 2.5: Playback Mode Detection

**File:** `Sources/MacParakeetViewModels/MediaPlayerViewModel.swift` (or utility)

```swift
enum PlaybackMode {
    case video    // YouTube or local video file — show split-pane
    case audio    // Local audio file — show scrubber bar + full-width content
    case none     // No playable media (e.g., file deleted) — full-width content, no player
}

func playbackMode(for transcription: Transcription) -> PlaybackMode {
    if transcription.sourceURL != nil {
        return .video  // YouTube — always video mode
    }
    if let path = transcription.filePath,
       FileManager.default.fileExists(atPath: path) {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let videoExtensions: Set = ["mp4", "mov", "mkv", "avi", "webm", "m4v"]
        return videoExtensions.contains(ext) ? .video : .audio
    }
    return .none  // File no longer exists
}
```

### Step 2.6: Tests

- Test VideoStreamService URL extraction with mock yt-dlp output
- Test MediaPlayerViewModel state transitions (idle → loading → ready)
- Test seek command updates AVPlayer correctly
- Test cache expiry triggers re-extraction
- Test playbackMode detection for YouTube, local video, local audio, missing file

---

## Phase 3: Detail View Revamp

**Goal:** Transform TranscriptResultView to adapt between two layouts based on playback mode. Add synced transcript highlighting and clickable timestamp seeking.

### Step 3.1: Adaptive Layout

**File:** `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift`

Use `playbackMode(for:)` to choose the layout:

**Video mode** (YouTube + local video files) — split-pane:
```
┌────────────────────┬──────────────────────────────┐
│  Video Player      │  [Transcript] [Summary] [Chat]│
│  (40% width)       │  (60% width)                  │
│                    │                                │
│  ┌──────────────┐  │  Content area                  │
│  │              │  │  (scrollable)                   │
│  │   AVPlayer   │  │                                │
│  │   16:9       │  │                                │
│  │              │  │                                │
│  └──────────────┘  │                                │
│                    │                                │
│  Video Title       │                                │
│  Channel Name      │                                │
│                    │                                │
│  [Mini] [Hide]     │                                │
└────────────────────┴──────────────────────────────┘
```

**Audio mode** (local audio files) — full-width with scrubber bar:
```
┌──────────────────────────────────────────────────┐
│  ▶  ━━━━━━━━━●━━━━━━━━━━━━━━  04:12 / 10:00  🔊 │
├──────────────────────────────────────────────────┤
│  [Transcript]  [Summary]  [Chat]                  │
│                                                   │
│  Content 100% width                               │
│  (full reading comfort, all vertical space)       │
│                                                   │
└──────────────────────────────────────────────────┘
```

**No media** (file deleted or unavailable) — full-width, no player (current behavior).

Key layout rules:
- Video panel: `minWidth: 320`, `idealWidth: 40%`, `maxWidth: 50%`
- Content panel: `minWidth: 400`, takes remaining space
- Audio scrubber bar: fixed ~44px height, pinned above tab bar
- Draggable divider between panels in video mode (use `HSplitView` or custom drag handle)

Video panel states:
- **Full**: Default 40% split, video + title + channel + controls
- **Mini**: Video shrinks to ~200x112 pinned top-left, content expands. Toggle via button.
- **Hidden**: Video panel collapses entirely. Small "Show Video" button appears in tab bar area.

Store visibility preference in UserDefaults (persists across sessions).

### Step 3.2: Video Panel Component

**New file:** `Sources/MacParakeet/Views/Transcription/TranscriptionVideoPanel.swift`

Contains:
- VideoPlayerView (the AVPlayer wrapper)
- Video title label (from `transcription.fileName`)
- Channel name label (from `transcription.channelName`)
- Collapse/mini/hide controls
- Loading state (spinner while HLS URL is being extracted)
- Error state ("Video unavailable offline" with retry button)
- Placeholder state (generic thumbnail while loading)

### Step 3.3: Synced Transcript Highlighting

**File:** `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift` (transcript pane section)

When the video player is active and playing:
- `VideoPlayerViewModel.currentTimeMs` drives highlighting
- The transcript segment whose `startMs <= currentTimeMs < endMs` gets a highlighted background (accent color at 15% opacity, rounded corners)
- Auto-scroll: the ScrollView scrolls to keep the active segment visible (with `ScrollViewReader` + `scrollTo(id:)`)
- Disable auto-scroll if user manually scrolls (re-enable when they tap a timestamp)

### Step 3.4: Clickable Timestamp Seeking

**File:** `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift`

Two integration points:

**Transcript tab:**
- Each timestamp label (`04:12`, `04:25`) becomes a tappable button
- Tap calls `videoPlayerViewModel.seek(toMs: segment.startMs)`
- If video is paused, seeking also starts playback
- Visual: timestamp text with accent color + underline on hover

**Chat tab:**
- When LLM responses reference timestamps (e.g., "at the 04:12 mark"), render them as tappable chips
- Chip UI: small rounded rect with play icon + timestamp text
- Tap seeks the video player
- Implementation: Parse timestamps from LLM markdown responses using regex (`\d{1,2}:\d{2}(?::\d{2})?`)
- This is best-effort — not all LLM responses will have parseable timestamps

### Step 3.5: Header Card Updates

**File:** `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift`

Update the header card (currently shows filename + metadata chips):
- For YouTube: show video title prominently + channel name below
- Move source badge, duration, word count chips to a subtitle line
- Back button stays
- Action bar (copy, export, retranscribe) stays

### Step 3.6: Tests

- Test video mode renders split-pane for YouTube transcriptions
- Test video mode renders split-pane for local video files
- Test audio mode renders scrubber bar + full-width content for audio files
- Test no-media mode renders full-width content with no player
- Test timestamp tap triggers seek on MediaPlayerViewModel
- Test transcript highlighting updates when currentTimeMs changes
- Test video panel visibility states (full/mini/hidden)
- Test collapsing video panel switches to audio-mode-style layout

---

## Phase 4: Home Page Revamp

**Goal:** Transform the TranscribeView home page from a vertical list into a polished landing with input cards and a thumbnail grid for recent transcriptions.

### Step 4.1: Input Cards Layout

**File:** `Sources/MacParakeet/Views/Transcription/TranscribeView.swift`

Replace the current stacked portal + YouTube card with a side-by-side layout:

```
┌─────────────────────────┬─────────────────────────┐
│  🔴 Paste YouTube URL   │  ☁️ Upload a Local File  │
│                         │                          │
│  Instantly transcribe   │  Drag and drop or browse │
│  any YouTube video.     │  your local files.       │
│                         │                          │
│  [url input] [Analyze]  │     [Select File]        │
└─────────────────────────┴─────────────────────────┘
```

- Two equal-width cards in an HStack
- YouTube card: URL text field + paste button + "Transcribe" button (keep existing validation logic)
- File card: drag-drop zone + "Select File" button (keep existing file picker logic)
- Both cards use the same height (alignment: .top with minimum height)
- Active transcription progress card appears ABOVE the input cards when transcribing

### Step 4.2: Thumbnail Grid for Recent Transcriptions

**File:** `Sources/MacParakeet/Views/Transcription/TranscribeView.swift`

Replace the current `RecentTranscriptionRow` list with a card grid:

```
RECENTLY TRANSCRIBED                    View All →
┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
│ thumbnail │  │ thumbnail │  │ thumbnail │  │ thumbnail │
│           │  │           │  │           │  │           │
│  HD 12:45 │  │     05:22 │  │     48:10 │  │     03:15 │
├──────────┤  ├──────────┤  ├──────────┤  ├──────────┤
│ Title     │  │ Title     │  │ Title     │  │ Title     │
│ Yesterday │  │ 2d ago    │  │ Last week │  │ Today     │
└──────────┘  └──────────┘  └──────────┘  └──────────┘
```

Card component (`TranscriptionThumbnailCard`):
- Thumbnail image (YouTube: cached thumbnail, video file: extracted frame, audio file: placeholder art)
- Duration badge overlay (bottom-right of thumbnail)
- Status badge overlay (top-left: "SUMMARY" if summary exists)
- Title (2-line max, truncated)
- Relative date ("Yesterday", "2 days ago")
- Tap opens detail view (existing navigation)
- Context menu: Delete, Copy transcript

Grid layout:
- LazyVGrid with adaptive columns, minimum 200px per card
- Show 8 most recent on home page
- "View All" link navigates to Library view (Phase 5)

### Step 4.3: Placeholder Artwork for Audio Files

**New file:** `Sources/MacParakeet/Views/Components/TranscriptionPlaceholderView.swift`

For transcriptions without thumbnails (audio-only files):
- Render a generated visual based on the transcription's properties
- Use the existing `SonicMandalaView` waveform pattern as the card thumbnail
- Tint with a color derived from the filename hash (deterministic, unique-ish per file)
- Aspect ratio matches thumbnail cards (16:9)

### Step 4.4: Tests

- Test input cards render side-by-side
- Test thumbnail grid shows correct number of items
- Test placeholder art renders for audio-only transcriptions
- Test "View All" navigation

---

## Phase 5: Library View

**Goal:** Add a dedicated library/history view for browsing all transcriptions with grid layout, filtering, search, and favorites.

### Step 5.1: New Sidebar Item

**File:** `Sources/MacParakeet/Views/MainWindowView.swift`

Add `.library` to the `SidebarItem` enum (or repurpose/rename an existing item). Place it after `.transcribe` in the primary items section.

Sidebar order becomes:
- Transcribe (home page with inputs)
- Library (all transcriptions grid)
- Dictations (voice dictation history)
- Vocabulary / Feedback / Settings

### Step 5.2: Library View

**New file:** `Sources/MacParakeet/Views/Transcription/TranscriptionLibraryView.swift`

Layout:

```
┌──────────────────────────────────────────────────┐
│  Library                            🔍 Search    │
│                                                   │
│  [All] [YouTube] [Local Files] [Favorites]       │
│                                                   │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌────────┐│
│  │ thumb   │ │ thumb   │ │ thumb   │ │ thumb  ││
│  │  12:45  │ │  05:22  │ │  48:10  │ │  03:15 ││
│  │ Title   │ │ Title   │ │ Title   │ │ Title  ││
│  │ Oct 24 ★│ │ Oct 22  │ │ Oct 21  │ │ Oct 18 ││
│  └─────────┘ └─────────┘ └─────────┘ └────────┘│
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌────────┐│
│  │ ...     │ │ ...     │ │ ...     │ │ ...    ││
│  └─────────┘ └─────────┘ └─────────┘ └────────┘│
└──────────────────────────────────────────────────┘
```

Components:
- **Filter bar**: Segmented control for All / YouTube / Local / Favorites
- **Search**: `.searchable()` modifier filtering by title and transcript content
- **Grid**: Same `TranscriptionThumbnailCard` component from Phase 4
- **Sort**: Default by date (newest first). Optional sort by duration or title.
- **Empty state**: "No transcriptions yet" with link back to Transcribe page

### Step 5.3: Favorites

**Database migration:**

```swift
migrator.registerMigration("v0.5-transcription-favorites") { db in
    try db.alter(table: "transcriptions") { t in
        t.add(column: "isFavorite", .boolean).defaults(to: false)
    }
}
```

**Model:** Add `public var isFavorite: Bool` to Transcription (default `false`).

**UI:** Star icon overlay on thumbnail card (bottom-left). Tap to toggle. Context menu option "Add to Favorites" / "Remove from Favorites".

**Repository:** Add `fetchFavorites()` query.

### Step 5.4: Library ViewModel

**New file:** `Sources/MacParakeetViewModels/TranscriptionLibraryViewModel.swift`

```swift
@MainActor @Observable
public final class TranscriptionLibraryViewModel {
    public var transcriptions: [Transcription] = []
    public var filter: LibraryFilter = .all  // .all, .youtube, .local, .favorites
    public var searchText: String = ""
    public var sortOrder: SortOrder = .dateDescending

    public var filteredTranscriptions: [Transcription] { ... }

    public func loadTranscriptions() async { ... }
    public func toggleFavorite(_ transcription: Transcription) async { ... }
    public func deleteTranscription(_ transcription: Transcription) async { ... }
}
```

### Step 5.5: Tests

- Test filter returns correct subsets
- Test search filters by title and transcript content
- Test favorite toggle persists to database
- Test sort orders work correctly

---

## Implementation Order & Dependencies

```
Phase 1 (Foundation)
  ├── 1.1 Model expansion
  ├── 1.2 DB migration
  ├── 1.3 yt-dlp metadata extraction
  ├── 1.4 Store metadata on transcription creation
  └── 1.5 Thumbnail cache service
       │
Phase 2 (Media Player) ──── depends on Phase 1.3 (stream URL uses yt-dlp)
  ├── 2.1 HLS URL extraction service
  ├── 2.2 AVPlayer SwiftUI wrapper
  ├── 2.3 Media player ViewModel (shared by video + audio modes)
  ├── 2.4 Audio scrubber bar component
  └── 2.5 Playback mode detection
       │
Phase 3 (Detail View) ──── depends on Phase 2 (needs video player)
  ├── 3.1 Split-pane layout
  ├── 3.2 Video panel component
  ├── 3.3 Synced transcript highlighting
  ├── 3.4 Clickable timestamp seeking
  └── 3.5 Header card updates
       │
Phase 4 (Home Page) ──── depends on Phase 1.5 (needs thumbnails)
  ├── 4.1 Input cards layout
  ├── 4.2 Thumbnail grid
  └── 4.3 Placeholder artwork
       │
Phase 5 (Library) ──── depends on Phase 4 (reuses thumbnail cards)
  ├── 5.1 Sidebar item
  ├── 5.2 Library view
  ├── 5.3 Favorites (DB + UI)
  └── 5.4 Library ViewModel
```

Phases 4 and 5 can be developed in parallel with Phase 3 since they share only the thumbnail card component.

## Out of Scope

- Tags / auto-categorization — Skipped for simplicity
- Channel grouping sidebar — Not enough value
- "Insights found" metric — UI bloat
- Video download/storage — Stream only
- Picture-in-Picture — Possible future enhancement
- Keyboard shortcuts for video control — Future polish
- Local video file playback requires file to still exist on disk (graceful fallback to audio mode or no-player if deleted)

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| HLS URL expires during playback | AVPlayer handles this gracefully (stalls). Re-extract on next play. Show "Reconnecting..." state. |
| yt-dlp URL extraction is slow (~2-3s) | Show loading spinner in video panel. Cache URL for session. Don't block transcript display. |
| YouTube blocks yt-dlp | Already a risk for transcription. yt-dlp auto-updates weekly. Same mitigation applies. |
| Large TranscriptResultView file (~1400 lines) | Split into sub-views: extract video panel, transcript pane, chat pane into separate files during Phase 3. |
| HSplitView doesn't style well on macOS | Fall back to GeometryReader + custom drag handle if needed. Test early. |
| Offline playback | Clear "unavailable offline" state. Transcript/summary/chat still work fully offline. |

## Design Tokens

Use existing `DesignSystem` tokens. New additions needed:

```swift
extension DesignSystem.Layout {
    static let videoPlayerMinWidth: CGFloat = 320
    static let videoPlayerIdealRatio: CGFloat = 0.4  // 40% of available width
    static let thumbnailCardMinWidth: CGFloat = 200
    static let thumbnailAspectRatio: CGFloat = 16/9
}
```

## Acceptance Criteria

### Phase 1 (Complete)
- [x] YouTube transcriptions store channelName and thumbnailURL
- [x] Existing transcriptions unaffected by migration (all fields optional)
- [x] Thumbnails cached locally and load from cache on repeat views
- [x] `swift test` passes

### Phase 2 (Complete)
- [x] AVPlayer streams YouTube video via HLS URL
- [x] AVPlayer plays local video files directly
- [x] Audio scrubber bar renders for audio-only files (thin horizontal bar, ~44px)
- [x] Playback mode auto-detected (video/audio/none) based on source type
- [x] Player shows loading/ready/error/offline states
- [x] Play/pause, seek, and scrub bar functional in both modes
- [x] Stream URL cached per session, re-extracted on expiry
- [x] `swift test` passes

### Phase 3 (Complete)
- [x] YouTube transcription detail shows split-pane (video left, tabs right)
- [x] Local video file transcription shows split-pane (video left, tabs right)
- [x] Local audio file transcription shows scrubber bar + full-width content
- [x] Clicking timestamp in transcript seeks player (works in both modes)
- [x] Active transcript segment highlighted during playback (works in both modes)
- [x] Video panel collapsible (full → mini → hidden; hidden = audio-mode layout)
- [x] `swift test` passes
- [ ] Chat tab timestamp chips (deferred — plan said "best-effort", low priority)

### Phase 4 (Mostly Complete)
- [x] Home page shows two input cards side-by-side
- [ ] Recent transcriptions displayed as thumbnail grid on home page (grid built, lives in Library view only)
- [x] YouTube cards show cached thumbnails
- [x] Audio-only cards show placeholder artwork (icon-based, not SonicMandalaView)
- [x] "View All" navigates to Library (via sidebar)
- [x] `swift test` passes

### Phase 5 (Complete)
- [x] Library view shows all transcriptions in grid
- [x] Filter by All/YouTube/Local/Favorites works
- [x] Search filters by title and transcript content
- [x] Favorite toggle persists to database
- [x] `swift test` passes
- [ ] Star overlay on thumbnail cards (favorites work via context menu only)

## Deferred Items
- Chat tab timestamp chips (best-effort, low priority)
- "Recently Transcribed" thumbnail grid on home page (content lives in Library sidebar instead)
- SonicMandalaView-based placeholder art for audio cards (using icon placeholder instead)
- Star icon overlay on thumbnail cards (toggle works via context menu)
