# SDLC Pipeline

The SDLC Pipeline plugin adds a full-width **Pipeline** tab to each repository. It derives one mutually exclusive, furthest-proven stage for each visible Job from authoritative Job state, landed commit, and configured deployment-stage evidence. It never stores a parallel pipeline state.

The ordered lifecycle is Triaging, Ready, Implementing, Review, Landing, and Landed, followed by the repository's `.syrus.yml` `deployment_stages` in declared order. Each stage reports totals, attention and aging counts, oldest age, and at most five highlighted Jobs. Epic and ungrouped totals make the overview useful without returning every Job.

`GET /api/v1/app/repositories/:repository_id/sdlc_pipeline` returns the bounded overview. Pass `stage=<stage-key>`, `page=<number>`, and `limit=<1..50>` for bounded drill-down. Terminal work is limited to the 50 most recently completed Jobs from the last 30 days. The endpoint requires an authenticated user with access through `Repository.accessible_to(Current.user)` and additionally applies `Job.visible_to(Current.user)`.

The response includes placement evidence for every returned item: its lifecycle state, landed SHA, or deployment-stage status and timestamp. Repository deployment configuration is read at request time, so edits are reflected without a refresh job or cache-owned state.

Disabling or deleting the plugin removes the tab, endpoint, frontend module, translations, and this documentation. Jobs, Epics, landing records, and deployment-stage statuses remain untouched.
