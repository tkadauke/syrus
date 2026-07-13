# Walkthrough Videos

The video walkthroughs feature lets operators record or attach a narrated screen recording to a Syrus Chat session. Gemini analyzes the video; the chat agent then uses the analysis to autonomously propose an Epic capturing the operator's intent.

## Enabling

```ruby
Feature.find_by(slug: 'video_walkthroughs').update(enabled: true)
```

**Also required:** Each user must configure a Gemini API key (`User#gemini_api_key`, set in `/credentials/edit`). The key is validated against the Gemini `models.list` endpoint at analysis time.

## Supported formats

| Format | Constraint |
|---|---|
| webm, mp4, mov | ≤15 minutes, ≤500 MB |

## How to attach a walkthrough

From the chat composer:
- **Record:** Click `+` → "Record a walkthrough" (captures full screen with mic)
- **File picker:** Click `+` → file picker
- **Drag-in:** Drag the video file into the composer

The operator can add a note describing what to focus on before sending.

## What happens after upload

1. `VideoWalkthroughAnalysisJob` uploads the video to Gemini's Files API and runs analysis (queue: `videos`, low concurrency).
2. Gemini produces a structured report: timestamped transcript, topical sections, flagged issues with severity, and `needs_closer_look` markers for moments where OCR or closer inspection is needed.
3. The compact 720p version of the video replaces the stored blob to save storage.
4. The video appears as a walkthrough card in the chat thread.
5. `ChatTurnJob` detects the walkthrough message and orients the agent with a brief prompt naming the available analysis tools.

## Agent tools for walkthroughs

The chat agent can call these MCP tools during analysis:

| Tool | What it does |
|---|---|
| `get_walkthrough_analysis` | Returns the full Gemini report plus crisp still frames as image blocks |
| `read_walkthrough_frame` | Extracts a screenshot at any timestamp for OCR of small on-screen text |
| `analyze_walkthrough_segment` | Re-analyzes a clip of the video at full resolution for finer detail |

Gemini is used for broad analysis and ASR (transcription). Claude handles OCR of small on-screen text (error codes, URLs, config values) from still frames, because Gemini Flash cannot reliably OCR video frames at any resolution.

## Video retention

`VideoWalkthroughPruneJob` runs daily and enforces:
- **Time ceiling:** `AppSetting.video_retention_days` (default: 7 days)
- **Storage budget:** `AppSetting.video_storage_budget_bytes` (default: 2 GB; LRU eviction when exceeded; `0` = unlimited)

The analysis report and extracted screenshots persist indefinitely. Only the raw video blob is pruned. The Gemini Files API retains uploads for ~48 hours, after which `analyze_walkthrough_segment` re-uploads the stored blob on demand.

## Desktop app recording

The desktop app's screen recorder (`+` → "Record a walkthrough"):
- Forces full-screen capture so the red-pen annotation overlay is always included.
- Records the mic simultaneously (macOS requires the `NSMicrophoneUsageDescription` entitlement).
- Displays a floating HUD with recording controls and a pen toggle button.

The **red pen** lets operators circle or underline areas of the screen while narrating. Gemini's analysis prompt looks for `user_flagged: true` on issues where the operator marked a moment. For hold-to-draw to work, macOS Accessibility permission must be granted; the app degrades to tap-to-arm if unavailable, without failing silently.

## When the flag is off

- The composer hides recording and video intake UI.
- Upload endpoints return 404.
- Walkthrough MCP tools are removed from the sidecar's advertised tool set.
- Already-analyzed threads keep their history read-only (media panel + message cards still render).
- `VideoWalkthroughPruneJob` continues running to enforce retention.
