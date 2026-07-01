# React SPA route inventory

_Captured 2026-05-30 as M0 for
`docs/plans/complete/react-spa-migration.md`._

_Status check 2026-06-07: complete as the migration inventory. The
routes listed here now describe the React-owned app shell, app JSON
APIs, and legacy compatibility redirects._

This inventory groups the current Rails routes into migration buckets.
It is not a pasted `bin/rails routes` dump; the source of truth remains
`config/routes.rb`. The goal is to make route ownership explicit before
React starts taking paths over.

`bin/rails routes --expanded` currently reports 241 routes including
Rails engine routes. Application routes occupy routes 1-215. The rest
are Turbo Native helpers, Action Mailbox, Active Storage, and Rails
health/storage internals.

## Buckets

| Bucket | Meaning |
|---|---|
| `spa-core` | Authenticated operator route that must become a React route. |
| `spa-admin` | Authenticated admin route that should migrate early, but can trail core operator routes where needed. |
| `legacy-html` | Keep server-rendered until late cleanup; either low value for SPA or part of auth/external flows. |
| `external-html` | Intentionally HTML because a third-party or Rails engine owns the flow. |
| `api-existing` | Existing token API. Keep stable for external callers; reuse service/serializer code only when appropriate. |
| `app-api-needed` | No browser JSON equivalent yet; add under `/api/v1/app/*` before migrating the owning page. |
| `engine` | Framework route, not part of the SPA migration. |

## Route groups

| Route group | Current owner | Bucket | Notes / target |
|---|---|---|---|
| `/` | `spa#show` + `/api/v1/app/dashboard` | `spa-core` | Migrated to the React dashboard shell. Must preserve subject/view/filter/page URL state. |
| `/dashboard` | `spa#show` + `/api/v1/app/dashboard` | `spa-core` | Same dashboard surface as root. Legacy ERB fallback removed. |
| `/dashboard/epics` | `spa#show` + `/api/v1/app/dashboard?subject=epic` | `spa-core` | Migrated to the React dashboard route tree. Legacy ERB fallback removed. |
| `/dashboard/jobs` | `spa#show` + `/api/v1/app/dashboard?subject=job` | `spa-core` | Migrated to the React dashboard route tree. Dashboard record links use React Router navigation, including `/app-shell` prefixed test routes. Legacy ERB fallback removed. |
| `/dashboard/workflows` | `spa#show` + `/api/v1/app/dashboard?subject=workflow` | `spa-core` | Migrated to the React dashboard route tree. Legacy ERB fallback removed. |
| `PATCH /dashboard/preferences` | `/api/v1/app/dashboard/preferences` | `spa-core` | Retired as an HTML/Turbo command; app API endpoint persists sort, visible-column, and Kanban lane preferences. |
| `POST /dashboard/jobs/bulk` | `/api/v1/app/dashboard/jobs/bulk` | `spa-core` | Retired as an HTML bulk form; app API endpoint mirrors retry, close, approve/review, and tag bulk actions with JSON responses. |
| `POST /dashboard/landing_pause` | `/api/v1/app/dashboard/landing_pause` | `spa-core` | Retired as an HTML command; app API endpoint toggles landing pause and re-enqueues the landing processor on resume. |
| `PATCH /dashboard/epics/:id/auto_approval` | `/api/v1/app/dashboard/epics/:id/auto_approval` | `spa-core` | Retired as an HTML command; app API endpoint updates dashboard Epic auto-approval state. |
| `/app-shell` | `spa#show` | `spa-core` | Hidden authenticated React shell used to prove the SPA asset, bootstrap API, and client routing path before taking over production routes. |
| `/jobs/new` | `spa#show` + `/api/v1/app/jobs/new`, `POST /api/v1/app/jobs` | `spa-core` | Migrated to the React direct-job form with internal React Router navigation after create. Legacy ERB fallback and HTML `POST /jobs` commands are removed. |
| `/jobs/:id` | `spa#show` + `/api/v1/app/jobs/:id`, `/api/v1/app/jobs/:id/timeline`, `/api/v1/app/jobs/:job_id/runs/:run_id/artifacts` | `spa-core` | Migrated to the React Job detail page. Internal repository/dependent-Job links use React Router navigation. Legacy ERB fallback and HTML member commands are removed. |
| `/jobs/:id/source` | `spa#show` + `/api/v1/app/jobs/:id/source` | `spa-core` | Migrated to the React source tab. Legacy ERB source browser removed. |
| job lifecycle commands | `/api/v1/app/jobs/:job_id/start`, `/run_again`, `/restart`, `/cancel`, `/approve`, `/unapprove`, `/reopen` | `spa-core` | App API endpoints cover core lifecycle transitions and emit job app-event invalidation. Legacy HTML commands are removed. |
| job run/workflow commands | `/api/v1/app/jobs/:job_id/*`, `/runs/:run_id/*`, `/workflows/:workflow_id/*` | `spa-core` | React Job detail uses app API commands for feedback polling, rebase, mergeability checks, resume, stop-run, retry-step, push-commits, and diagnostics. Legacy HTML command routes are removed. |
| job metadata commands | `/api/v1/app/jobs/:job_id/tags`, `/dependencies`, `/dependencies/override`, `/stack_base`, `/mark_valid` | `spa-core` | React Job detail uses app API endpoints for tag add/remove, manual dependency add/remove, dependency override, stack base update, and invalid-job requeue. Legacy HTML commands are removed. |
| job grade logs | `/api/v1/app/jobs/:job_id/runs/:run_id/grade_log` | `spa-core` | React Job detail fetches grade logs as JSON and renders them inline. The legacy plaintext endpoint is removed. |
| job attachments | `/api/v1/app/jobs/:job_id/attachments` | `spa-core` | React Job detail uses app API upload/delete endpoints that return compact attachment rows and emit job app-event invalidation. Legacy HTML attachment routes are removed. |
| job pins | `/api/v1/app/jobs/:job_id/pin` | `spa-core` | React uses the app API pin/unpin endpoint returning the new pin state and emitting job app-event invalidation. Legacy HTML pin routes are removed. |
| `/epics/:id` | `spa#show` + `/api/v1/app/epics/:id` | `spa-core` | Migrated to the React Epic detail page with child Jobs, dependency graph data, internal React Router navigation, and app API state/archive commands. Legacy ERB detail fallback removed. |
| `/epics/new`, `/epics/:id/edit` | `spa#show` + `/api/v1/app/epics*` | `spa-core` | Migrated to the React Epic form with internal React Router navigation after save. Legacy ERB form fallbacks and HTML `POST/PATCH /epics` commands removed. |
| Epic commands | `/api/v1/app/epics/:id/archive`, `/state` | `spa-core` | React uses app API command endpoints for archive and state transitions. Legacy HTML commands are removed. |
| `/epics/:id/graph` | removed | `spa-core` | Legacy Turbo drawer endpoint removed with the ERB dashboard. React Epic detail renders the dependency graph from `/api/v1/app/epics/:id` graph data. |
| `/epics`, `/jobs`, `/workflows` redirects | route redirects | `spa-core` | Compatibility shortcuts now redirect to React-owned `/dashboard/epics`, `/dashboard/jobs`, and `/dashboard/workflows` while preserving non-`subject` query params. |
| `/repositories` | `spa#show` + `/api/v1/app/repositories` | `spa-core` | Migrated to the React repository list with app API poll/archive/unarchive commands. Internal add/show/edit links use React Router navigation. Legacy ERB list fallback removed. |
| `/repositories/new`, `/repositories/:id/edit`, `POST/PATCH /repositories` | `spa#show` + `/api/v1/app/repositories*` | `spa-core` | Migrated to the React repository form with app API GitHub owner/repo/branch selectors and internal React Router navigation after save. Legacy ERB form fallbacks and HTML `POST/PATCH /repositories` commands removed. |
| `/repositories/:id` | `spa#show` + `/api/v1/app/repositories/:id*` | `spa-core` | Migrated to the React repository detail overview and GitHub Issues tab. Internal tabs/actions/recent Job links use React Router navigation; GitHub links stay external anchors. Legacy ERB detail fallback removed. |
| repository collection JSON helpers | `/api/v1/app/repositories/owners`, `/repos`, `/branches` | `spa-core` | React repository form uses app API selectors; legacy AJAX helpers removed with the ERB form fallback. |
| repository commands | `/api/v1/app/repositories/:id/poll`, `/archive`, `/unarchive`, `/retry_failed_jobs` | `spa-core` | React repository list and detail use app API command endpoints for poll, archive/unarchive, and retry failed jobs. Legacy HTML commands are removed. |
| repository GitHub issues | `/api/v1/app/repositories/:id/issues*` | `spa-core` | React repository detail owns issue listing plus comment/close/delegate/bulk commands. Legacy HTML issue routes are removed. |
| repository notes | `/api/v1/app/repositories/:id/notes`, `/api/v1/app/repositories/:repository_id/notes/:id` | `spa-core` | React repository overview uses app API mutations for note add/remove. Legacy HTML note routes are removed. |
| repository documents | `spa#show` + `/api/v1/app/repositories/:id/documents` | `spa-core` | Migrated to the React repository documents page with app API upload/delete. Legacy ERB fallback and HTML document mutation routes are removed. |
| repository scheduled task helpers | `spa#show` + `/api/v1/app/repositories/:id/scheduled_tasks*` | `spa-core` | Migrated to React for the per-repository scheduled-task tab and repository-scoped new form. Legacy ERB fallback and HTML mutation routes are removed. |
| `POST /api/v1/app/chats` | app API only | `spa-core` | Chat creation is handled directly by the app API. Empty chats are created before navigating to `/chats/:id`, which renders the hero compose layout. Legacy ERB fallback, HTML `POST /chats`, and the retired `/chats/new` routes are removed. |
| `/chats/:id` | `spa#show` + `/api/v1/app/chats/:id`, `/api/v1/app/chats/:id/messages` | `spa-core` | Migrated to the React chat renderer with frontend Markdown rendering, typed message pagination, app API message sending, internal React Router navigation, and payload-carrying app events for live message tail/header/control updates. Rails no longer renders chat message/header/control Turbo partials, and the legacy ERB fallback is removed. |
| chat commands | `/api/v1/app/chats/:id/bookmarks`, `/attachments`, `/proposals/:proposal_id/*`, `/pending_actions/:pending_action_id/*` | `spa-core` | React chat uses typed app API mutations for bookmarks, attachment add/remove, proposal confirm/reject, and pending-action confirm/cancel. Legacy HTML command routes are removed. |
| chat whiteboard | `/api/v1/app/chats/:id/whiteboard` | `spa-core` | React chat mounts the Excalidraw whiteboard, saves through the app API, and receives app-event invalidation for agent/operator updates. Legacy `chat_whiteboards#show/update` and Turbo whiteboard broadcasts are removed. |
| `/scheduled_tasks` | `spa#show` + `/api/v1/app/scheduled_tasks*` | `spa-core` | Migrated to the React scheduled-task CRUD shell with internal React Router links to repositories, Jobs, and task detail pages. Legacy ERB fallback is removed. |
| scheduled task commands | `/api/v1/app/scheduled_tasks/:id/*` | `spa-core` | React uses app API command endpoints for pause, resume, fire-now, update, and archive. Legacy HTML commands are removed. |
| `/cron_templates` | `spa#show` + `/api/v1/app/cron_templates` | `spa-core` | Migrated to the React cron-template CRUD shell with internal React Router links for settings nav, applied tasks, repository apply actions, and app API create/update/delete. Legacy ERB fallback and HTML cron-template mutation routes are removed. |
| `/smart_folders` | `spa#show` + `/api/v1/app/smart_folders` | `spa-core` | Migrated to the React smart-folder manage shell with internal React Router dashboard navigation and app API create/update/delete. Dashboard filter saves use the app API; legacy HTML smart-folder routes are removed. |
| `/tags` | `spa#show` + `/api/v1/app/tags` | `spa-core` | Migrated to the React tags shell with internal React Router settings navigation and app API create/update/delete. Legacy ERB fallback and HTML tag mutation routes are removed. |
| `/filters/fk_options` | `/api/v1/app/filters/fk_options` | `spa-core` | Browser typeahead uses the app API endpoint with normalized `{ options: [...] }`; legacy JSON helper is removed. |
| `/credentials/edit`, `/credentials` | `spa#show` + `/api/v1/app/credentials` | `spa-core` | Migrated to the React credentials/settings page. Legacy ERB fallback and HTML credential mutation routes are removed. |
| credential token commands | `/api/v1/app/credentials/*api_token` | `spa-core` | React uses app API commands returning masked token state plus one-time plaintext on rotation. Legacy HTML token command routes are removed. |
| `/account/documents` | `/api/v1/app/credentials/documents` | `spa-core` | React uses app API upload/delete endpoints for credential-page documents. Legacy HTML document routes are removed. |
| `/settings` | `spa#show` | `spa-core` | Migrated as the per-user credentials alias. `/settings/edit` remains the separate admin app-settings surface. |
| `/settings/edit` | `spa#show` + `/api/v1/app/admin/settings` | `spa-admin` | Migrated to the React app settings shell. Legacy ERB fallback and HTML settings mutation route are removed. |
| `/invitations` | `spa#show` + `/api/v1/app/admin/invitations` | `spa-admin` | Migrated to the React invitations shell with app API create/revoke. Legacy ERB fallback and HTML invitation mutation routes are removed. |
| `/admin` | `spa#show` | `spa-admin` | Migrated to the React admin overview shell with internal React Router metric links; legacy ERB fallback is removed. |
| `/admin/queue`, `/admin/queue/:tab` | `spa#show` + `/api/v1/app/admin/queue*` | `spa-admin` | Migrated to the React admin queue shell with app API reaper command. Legacy ERB fallback and HTML reaper route are removed. |
| `/admin/stuck` | `spa#show` | `spa-admin` | Migrated to the React stuck-items shell with internal React Router links to Jobs and transcripts. Legacy ERB fallback is removed. |
| `/admin/processes`, `/admin/processes/:id` | `spa#show` + `/api/v1/app/admin/processes*` | `spa-admin` | Migrated to the React process inventory/detail shell with internal React Router transcript links and app API kill. Legacy ERB fallback and HTML kill route are removed. |
| `/admin/runs/:run_id/transcript` | `spa#show` | `spa-admin` | Migrated to the React transcript viewer with internal React Router back-to-Job navigation. Legacy ERB fallback is removed. |
| `/admin/runs/:run_id/transcript/download` | `admin/transcripts#download` | `legacy-html` | Keep as regular download endpoint. |
| `/admin/users`, `/admin/users/:id` | `spa#show` + `/api/v1/app/admin/users*` | `spa-admin` | Migrated to the React users list/detail shell with app API scheduling commands. Legacy ERB fallback and HTML scheduling command routes are removed. |
| `/admin/console` | `spa#show` + `/api/v1/app/admin/console*` | `spa-admin` | Migrated to the React operator console with app API kill-switch/cache commands. Legacy ERB fallback and HTML console command routes are removed. |
| `/admin/installations` | `spa#show` + `/api/v1/app/admin/installations` | `spa-admin` | Migrated to the React GitHub App installations page with app API refresh. Legacy ERB fallback and HTML refresh route are removed. |
| `/admin/github_app/register`, `/admin/github_app/callback`, `/admin/github_app/confirm` | `admin/github_app` | `external-html` | Third-party manifest/callback flow. Leave server-rendered unless there is a concrete SPA benefit. |
| `/session/new`, `POST/DELETE /session` | `sessions` resource | `legacy-html` | Keep server-rendered until late. SPA handles 401 by navigating here. |
| `/users/new`, `POST /users` | `users#new/create` | `legacy-html` | First-user bootstrap path; low value for SPA. |
| `/passwords/new`, `/passwords/:token/edit`, password mutations | `passwords` resource | `legacy-html` | Keep server-rendered unless auth UX gets a dedicated pass. |
| bug reports | `/api/v1/app/bug_reports` | `spa-core` | React app chrome and any legacy layout chrome post bug reports to the app API. Legacy HTML route is removed. |
| `/pwa/*` | `app/views/pwa/*` | `legacy-html` | Static/dynamic manifest assets. |
| `/up` | `rails/health#show` | `engine` | Health check; unrelated. |
| `/api/v1/admin/*` | `api/v1/admin/*` | `api-existing` | Token-auth external/admin API. Keep stable; do not repurpose for session-cookie SPA if the browser needs different contracts. |
| Turbo Native routes | `turbo/native/navigation` | `engine` | Remove when Turbo is retired if no longer mounted by the gem. |
| Action Mailbox routes | Rails engine | `engine` | Unrelated. |
| Active Storage routes | Rails engine | `engine` | Keep for uploads/downloads. |

## Stimulus ownership by migration slice

| Slice | Controllers to retire or rewrite in React |
|---|---|
| SPA shell | `split_button`, `flash`, `bug_report`, global `form_validation` compatibility |
| Admin diagnostics | `auto_refresh`, `tabs` |
| Dashboard | Retired ERB-only controllers: `chip_bar`, `column_picker`, `sort_select`, `bulk_jobs`, `kanban`, `epic_graph_drawer`, `filter_memory`. Generic `checkbox_persistence` and `details_persistence` remain only in the legacy application layout. |
| Job detail/source | React owns Job detail/source. Legacy detail/source Stimulus controllers `approval_review`, `attachment_drop`, `iteration_tabs`, `retry_context`, `run_timer`, `transcript_toggle`, `source_highlight`, and `source_tree` are retired. |
| Chat/whiteboard | retired with the React chat route |
| Repository/settings/forms | `credentials_form`, `scheduled_task_form`, `document_upload`, `auto_submit` |
| Shared visual helpers | `relative_time` can become a React utility as remaining legacy pages migrate. The legacy Mermaid graph drawer has been removed. |

## First migration slice

Use admin diagnostics as the first real page migration after the
scaffolding/bootstrap PR:

1. `/admin` (migrated)
2. `/admin/queue/:tab` (migrated)
3. `/admin/stuck` (migrated)
4. `/admin/processes` (migrated)
5. `/admin/runs/:run_id/transcript` (migrated)

Rationale:

- The operator-facing risk is lower than `jobs/:id` and `chats/:id`.
- The existing token admin API and admin service objects already define
  much of the read model.
- Tables, filters, polling/realtime invalidation, command buttons, and
  transcript pagination exercise the SPA architecture without touching
  the agent execution loop.

## API work implied before page migration

The first implementation phase needs these app API primitives before
any page can move safely:

- `/api/v1/app/bootstrap`
- session-cookie API base controller with JSON 401/403 handling
- shared browser response/error envelope
- route-level migration flag or server-side route switch
- Action Cable JSON event envelope and one low-risk channel

After that, admin diagnostics can reuse or adapt existing admin
serializers one endpoint at a time.
