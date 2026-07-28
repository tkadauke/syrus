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

**Workspace reclamation.** A Coding-Mode checkout (writable full clone + installed dependencies) is commonly 1–2 GB, so Syrus reclaims that disk aggressively while never losing work:

- **On successful handoff** — once the branch is pushed and the PR is open, the checkout is fully reproducible from the remote, so `ChatCodingWorkspaceReclaimJob` (on the `chat` queue) frees it.
- **When idle** — `WorkflowWorkspacePruneJob` reclaims checkouts inactive longer than `ChatWorkspace::RECLAIM_IDLE_CODING_AFTER` (48 h).
- **Under disk pressure** — when retained checkouts exceed `AppSetting.chat_coding_workspace_budget_mb` (`0` = unlimited), the least-recently-active are LRU-evicted.

Reclamation is safe and transparent: before deleting, any un-pushed commits are pushed to the coding branch, and any uncommitted work is snapshotted into a WIP commit pushed to a `syrus-wip/chat-<id>` tag ref (keeping the branch history clean). The session keeps its `coding_checkout_branch`, so the next chat turn re-clones the branch and re-applies the WIP snapshot before the agent runs — the agent cannot tell the workspace was ever removed. If a backup push fails, the on-disk checkout is preserved rather than deleted. See `AppSetting.chat_coding_workspace_budget_mb`.

**Multi-pod (Kubernetes) setup.** The three coding sidebar endpoints (`coding_files`, `coding_file`, `coding_diff`) proxy to a lightweight HTTP relay running on the `chat` queue worker. The relay address is recorded per-session in `chat_sessions.coding_relay_address`. For web pods to reach the worker relay, set `SYRUS_TERMINAL_HOST` to the worker pod IP via the Downward API field `status.podIP` on worker pods — the same setting used by the terminal feature. In single-host and Docker Compose deployments the relay binds to `127.0.0.1` and both web and worker share the same host, so no additional configuration is needed.

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
