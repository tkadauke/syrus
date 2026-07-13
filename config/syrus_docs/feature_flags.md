# Feature Flags

Syrus uses feature flags to gate experimental and operational behaviors. Flags are declared in `config/features.yml` and toggled in the admin UI under the Features tab (or via Rails console: `Feature.find_by(slug: 'slug').update(enabled: true)`).

All flags default to `false` (disabled).

## terminal

**Category:** Labs

Enables interactive terminal access inside workflow runs. When enabled, operators can open a PTY session attached to the agent's workspace from the Job detail page.

The terminal relay address is configured via `SYRUS_TERMINAL_HOST`. See the Terminal documentation for architecture details and how to enable.

## coding_mode

**Category:** Labs

Enables Coding Mode for Syrus Chat. When active, the chat workspace gets a writable full clone on a dedicated branch so the agent can implement code directly during a chat session instead of just planning. After the agent commits, it calls `complete_implement_step` or `submit_coding_changes` to hand off to a `coding_handoff` workflow, which requires operator confirmation before dispatching.

## video_walkthroughs

**Category:** Labs

**Requires:** A Gemini API key configured on the user's account (`User#gemini_api_key`).

Enables walkthrough video intake in Syrus Chat. Operators can record or drag in a narrated screen recording (webm/mp4/mov, ≤15 min, ≤500 MB). Gemini analyzes the video; the chat agent uses the analysis to propose an Epic. See the Video Walkthroughs documentation for the full flow.

## local_mode

**Category:** Labs

Enables the Local chat mode and the `syrus local` daemon command. The agent connects to a daemon running on the user's local machine via a reverse WebSocket tunnel to read/write files and run commands locally, without requiring a server-side clone.

## chat_polish

**Category:** UI Experiments

Adds subtle motion-safe chat animations: new messages fade in, the jump-to-bottom scroll is smooth. Respects the user's `prefers-reduced-motion` setting.

## performance_logging

**Category:** Operations

Records structured slow-request, SQL query, and phase-timing events to logs and a short-lived admin diagnostics buffer. Useful for profiling production performance. No user-facing impact.
