# SDLC Pipeline

The SDLC Pipeline plugin adds a full-width **Pipeline** tab to each repository. It derives one mutually exclusive, furthest-proven stage for each visible Job from authoritative Job state, landed commit, and configured deployment-stage evidence. It never stores a parallel pipeline state.

The ordered lifecycle is Triaging, Ready, Implementing, Review, Landing, and Landed, followed by the repository's `.syrus.yml` `deployment_stages` in declared order. Each stage reports totals, attention and aging counts, oldest age, and at most five highlighted Jobs. Epic and ungrouped totals make the overview useful without returning every Job.

The full-width board scrolls horizontally without moving when its 30-second refresh runs. Soft edge masks, previous/next controls, a stage navigator, and left/right keyboard navigation expose offscreen stages. Pinned work, attention items, and recent changes are promoted above ordinary work; the rest remains compressed into linked Epic and ungrouped aggregates. Selecting a stage opens a paged, bounded list. Lifecycle lanes link to the existing Job and Epic management surfaces. Deployment lanes are explicitly observational: their placement comes from recorded delivery evidence and cannot be changed or dragged on this page.

Landed remains a separate lane before any configured deployment stages, making the deployment gap visible. The final configured delivery stage acts as the bounded recent-release tail; older entries fade modestly by age, with a contrast floor, while evidence type remains explicit. With no `deployment_stages` configuration the lifecycle and Landed lanes still work and the page explains how to enable delivery evidence. Loading, empty, filtered-empty, and API-error states are rendered in place, including a retry action.

`GET /api/v1/app/repositories/:repository_id/sdlc_pipeline` returns the bounded overview. Pass `stage=<stage-key>`, `page=<number>`, and `limit=<1..50>` for bounded drill-down. Terminal work is limited to the 50 most recently completed Jobs from the last 30 days. The endpoint requires an authenticated user with access through `Repository.accessible_to(Current.user)` and additionally applies `Job.visible_to(Current.user)`.

The response includes placement evidence for every returned item: its lifecycle state, landed SHA, or deployment-stage status and timestamp. Repository deployment configuration is read at request time, so edits are reflected without a refresh job or cache-owned state.

Disabling or deleting the plugin removes the tab, endpoint, frontend module, translations, and this documentation. Jobs, Epics, landing records, and deployment-stage statuses remain untouched.
