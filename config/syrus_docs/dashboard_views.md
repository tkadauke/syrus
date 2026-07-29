# Dashboard Views

The Jobs and Epics dashboards support three view modes toggled from the toolbar:

## list

Default tabular view. Supports column visibility, sorting, and pagination. Columns are configurable per-user per-subject.

## kanban

Board view grouped by configurable lanes (e.g. Queued, Running, Succeeded). Lanes are configurable per-user per-subject. Not available on the Workflows dashboard.

## dependencies

Topological dependency graph showing jobs (or epics) as nodes and their `Depends-on` / `Blocked-by` relationships as directed edges. Nodes are placed in columns by dependency depth: Layer 0 has no blockers, Layer N is blocked by Layer N-1 work. Clicking a node navigates to the job or epic detail page.

Not available on the Workflows dashboard.

**Empty states:**
- If the active filter matches no jobs/epics, the view shows "No [subject] match this view."
- If nodes are present but none have dependency edges between them (all at Layer 0), the view shows "No dependency relationships in the current view."

**Data source:** `GET /api/v1/app/jobs/graph` and `GET /api/v1/app/epics/graph`. Both endpoints accept the same filter params as the corresponding index endpoints (`repo`, `state`, `q`, `smart_folder_id`) and return `{ nodes, edges }` scoped to `accessible_to(Current.user)`.

## View preference persistence

The selected view is persisted per `[subject, smart_folder_id]` pair and restored on next load. Preferences are stored via `User#update_dashboard_folder_preferences!` and resolved by `DashboardPayload#folder_pref_view`. All three view values (`list`, `kanban`, `dependencies`) are valid persisted values.
