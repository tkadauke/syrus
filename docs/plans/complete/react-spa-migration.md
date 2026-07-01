# React SPA migration

_Captured 2026-05-30. Target state: Syrus is a React single-page
application backed by Rails JSON APIs and Action Cable events. Rails
keeps the domain model, jobs, GitHub integration, auth, queues,
workers, and deployment shape. ERB/Hotwire becomes an interim
compatibility layer and is removed page-by-page._

_Status check 2026-06-07: complete. Authenticated operator, admin,
settings, repository, dashboard, job, chat, and setup surfaces are
owned by the React SPA and `/api/v1/app/*` JSON APIs. Legacy app
ERB/Stimulus/Hotwire surfaces have been removed; the remaining
server-rendered templates are mailers, PWA assets, and the SPA shell._

## Why this is a real migration

The current UI is not "Rails views with a little JavaScript." It is a
Hotwire app:

- Server-rendered ERB owns routing, forms, validation, flash messages,
  and most conditional UI.
- `broadcasts_refreshes` / `broadcasts_refreshes_to` tell pages to
  re-render server-side and Turbo morph the result into the DOM.
- Stimulus controllers preserve local state around those morph cycles.
- The React footprint is currently a single island: the Excalidraw
  whiteboard, mounted from a Stimulus controller.

A SPA changes the update model. Instead of "model changed, re-render
the page, morph it," the frontend needs stable JSON resources,
explicit mutation endpoints, realtime invalidation events, and client
state that survives navigation without relying on Turbo.

## Target architecture

### Backend

- Rails remains the only backend.
- Existing HTML controllers stay until their pages are migrated.
- New API controllers live under `/api/v1/app/*`.
- Existing `/api/v1/admin/*` endpoints remain for external/admin
  automation, but the SPA may reuse serializer/service code where it
  matches the browser contract.
- Session-cookie auth remains for the browser app.
- CSRF remains enabled for cookie-authenticated mutations.
- Action Cable remains the realtime transport, using Solid Cable in
  dev/prod as today.

### Frontend

- React 18+ with TypeScript.
- Vite build pipeline, integrated into Rails assets/deploy.
- React Router for client routing.
- TanStack Query for server state, cache invalidation, optimistic
  mutations where useful, and background refetch.
- Plain Action Cable consumer wrapper for subscriptions.
- Tailwind remains the styling system.
- Existing Stimulus controllers are retired as their owning pages move
  to React.

### Realtime model

Do not try to make React consume Turbo Streams. During migration,
broadcast both:

1. Turbo refresh/stream events for old ERB pages.
2. JSON app events for SPA pages.

SPA event shape:

```json
{
  "type": "job.updated",
  "resource": "job",
  "id": 123,
  "scope": { "user_id": 9, "repository_id": 4 },
  "changed": ["state", "pr_number", "updated_at"],
  "occurred_at": "2026-05-30T12:34:56Z"
}
```

Events invalidate query keys; they should not carry full page state.
Exceptions are high-frequency stream content like chat messages and
run transcript chunks, where appending a compact payload is cheaper
than forcing a refetch after every token/chunk.

## Non-goals

- Do not rewrite Rails models, workflow execution, polling, or queue
  plumbing as part of the frontend migration.
- Do not change auth semantics unless a page migration requires a
  browser API equivalent.
- Do not create a separate Node backend.
- Do not remove Turbo until every route that depends on it has a SPA
  replacement.
- Do not pause feature work for a big-bang rewrite.

## Build order

Each milestone should be deployable independently. Old ERB pages and
new React routes must coexist until M10 retires Hotwire.

### M0 - Inventory and contracts

Outcome: every current page has an owner, migration bucket, and API
contract sketch.

- Add `docs/plans/complete/react-spa-route-inventory.md`.
- Classify every route:
  - `spa-core`: must be first-class React route.
  - `spa-admin`: admin route, can migrate after core.
  - `legacy-html`: keep as HTML until late cleanup.
  - `external-html`: intentionally remains server-rendered, e.g.
    GitHub App manifest/callback flows if easier.
- For each `spa-core` route, document:
  - existing controller/action
  - view partials used
  - Stimulus controllers attached
  - Turbo stream subscriptions
  - required reads
  - required mutations
  - realtime events needed
- Acceptance:
  - route inventory covers all entries in `config/routes.rb`
  - first migration slice is chosen and small enough to ship

Suggested first slice: admin overview + queue. It already has JSON-ish
service boundaries and low risk compared with chat/job show.

### M1 - React build pipeline

Outcome: Rails can serve one React island from the production image,
with tests and deploy wiring in place.

- Add Vite + TypeScript + React.
- Keep importmap for existing Hotwire code during migration.
- Build output lands in Rails assets and works in `bin/deploy`.
- Add scripts:
  - `bin/test-js` continues to run existing node controller specs.
  - add `bin/test-react` for Vitest.
  - update `bin/test` to run RSpec, existing JS specs, and React tests.
- Add minimal React mount:
  - `/app-shell` or hidden admin-only route
  - renders current user and app revision from a bootstrap endpoint
- Add frontend folders:
  - `app/frontend/main.tsx`
  - `app/frontend/routes/`
  - `app/frontend/api/`
  - `app/frontend/components/`
  - `app/frontend/lib/actionCable.ts`
- Acceptance:
  - production Docker build includes compiled React assets
  - `bin/test` covers Ruby, legacy JS, and React tests
  - old ERB pages still work

### M2 - Browser API foundation

Outcome: the SPA has stable primitives for auth, bootstrap state,
errors, pagination, and mutations.

- Add `/api/v1/app/bootstrap`.
  - current user
  - roles/admin flag
  - app revision/revision URL
  - feature flags
  - CSRF token or documented meta-token read path
- Add shared API response conventions:
  - timestamps are ISO8601 strings
  - enum values are raw model strings
  - validation errors use `{ errors: { field: ["message"] } }`
  - command failures use `{ error: "code", message: "..." }`
  - list endpoints use `{ items, page, per_page, total }`
- Add frontend API client:
  - same-origin credentials
  - CSRF on mutating requests
  - typed error objects
  - redirect to sign-in on 401
- Add serializer pattern for browser payloads.
  - Prefer small PORO serializers under `app/services/app_api/`.
  - Avoid leaking full ActiveRecord objects into JSON ad hoc from
    controllers.
- Acceptance:
  - request specs cover bootstrap, auth failure, validation failure,
    pagination shape, and one mutation
  - React tests cover API error handling

### M3 - JSON realtime foundation

Outcome: React pages can stay live without Turbo morphs.

- Add app Action Cable channels:
  - `AppUserChannel` for dashboard/global user-scoped changes
  - `AppJobChannel` for job show/workflow/run changes
  - `AppRepositoryChannel` for repository-scoped lists
  - `AppChatChannel` for chat messages, controls, header, whiteboard
  - `AppAdminChannel` for admin overview/queue/process diagnostics
- Add a small broadcast service:
  - `AppEvents.broadcast(user:, type:, resource:, id:, changed: [], payload: nil)`
  - wraps stream names and event envelopes
  - called alongside existing Turbo broadcasts
- Start with invalidation-only events for low-frequency state changes.
- Use payload-carrying append events for chat messages/transcript chunks
  only after those pages migrate.
- Frontend event handling:
  - maps event types to TanStack Query invalidations
  - batches invalidations on animation frame or short debounce
  - logs unknown event types in development
- Acceptance:
  - unit/request/channel specs prove an updated Job emits a JSON event
    without breaking Turbo broadcasts
  - React test proves an event invalidates the correct query key

### M4 - SPA shell and navigation

Outcome: authenticated users enter a React shell for migrated routes,
while unmigrated routes still fall through to Rails HTML.

- Add a React shell route, mounted from the Rails layout or a dedicated
  `SpaController#show`.
- Implement app chrome:
  - top nav
  - admin pill
  - settings/sign-out menu
  - system alerts
  - flash/toast area
  - bug report launcher or compatibility mount
  - footer revision
- Routing strategy:
  - React owns migrated paths.
  - Links to unmigrated paths use normal document navigation.
  - Rails serves the SPA entry for migrated paths and any React Router
    subroute.
- Add a migration flag per route so rollout can be reversed by config
  without reverting code.
- Acceptance:
  - direct load and client navigation both work for a migrated route
  - old HTML route direct loads still work
  - sign-in/sign-out flows still work

### M5 - Admin diagnostics first

Outcome: prove the architecture on pages with real data and relatively
low operator workflow risk.

Migrate:

- `/admin`
- `/admin/queue/:tab`
- `/admin/stuck`
- `/admin/processes`
- `/admin/runs/:run_id/transcript`

Work:

- Reuse existing admin service objects where possible.
- Add `/api/v1/app/admin/*` endpoints only when the public admin API
  shape is wrong for the browser.
- Add React table primitives:
  - pagination
  - filters
  - stale/health badges
  - destructive action confirmation
  - empty/error/loading states
- Add realtime invalidation from `AppAdminChannel`.
- Acceptance:
  - every migrated admin page has request specs and React tests
  - kill/reap/pause actions behave the same as ERB pages
  - old admin pages can be disabled after parity is confirmed

### M6 - Dashboard, epics, jobs list, workflows list

Outcome: the main operator dashboard becomes SPA-native.

Migrate:

- `/dashboard`
- `/dashboard/epics`
- `/dashboard/jobs`
- `/dashboard/workflows`
- smart folder/chip/filter interactions used by those pages
- dashboard preference updates
- bulk job actions

API:

- `GET /api/v1/app/dashboard`
- `GET /api/v1/app/epics`
- `GET /api/v1/app/jobs`
- `GET /api/v1/app/workflows`
- `PATCH /api/v1/app/dashboard/preferences`
- `POST /api/v1/app/dashboard/jobs/bulk`
- smart folder CRUD endpoints with browser-shaped responses

Realtime:

- `job.created`, `job.updated`, `job.closed`
- `workflow.created`, `workflow.updated`
- `epic.updated`
- `repository.updated` when dashboard labels/filters depend on it

Acceptance:

- pagination matches the existing standard
- current URL query params fully represent filters/view/page
- browser back/forward restores dashboard state
- live job state changes update without page reload
- bulk selections survive realtime updates unless the selected item
  disappears from the current filtered result

### M7 - Job detail and source browser

Outcome: the most important operational detail page no longer depends
on Turbo morphs.

Migrate:

- `/jobs/:id`
- `/jobs/:id/source`
- attachments on job show
- dependency controls
- approval/retry/rebase/resume/stop/push actions
- iteration/workflow/step/run panels

API:

- `GET /api/v1/app/jobs/:id`
- `GET /api/v1/app/jobs/:id/timeline`
- `GET /api/v1/app/jobs/:id/source`
- one command endpoint per existing member action, or a generic
  `POST /api/v1/app/jobs/:id/commands` if the command contract is
  uniform enough
- attachment upload/delete endpoints

Realtime:

- `job.updated`
- `workflow.updated`
- `step.updated`
- `run.updated`
- `job_log.appended`
- `run_health_snapshot.created`

UI concerns:

- Preserve transcript scroll position without `data-turbo-permanent`.
- Render high-volume logs incrementally; do not refetch the entire job
  after every log append.
- Keep dangerous command buttons disabled while the backend says the
  transition is illegal. Do not rely on the client as the guard.

Acceptance:

- a running job updates state/logs live for at least 30 minutes without
  unbounded memory growth
- every existing Job member action has request coverage and a React
  interaction test
- source browser handles large trees without blocking the main thread

### M8 - Chat and whiteboard

Outcome: the most interactive surface becomes React-native.

Migrate:

- `/chats/:id`
- message compose/stop/refresh/reset
- proposals and pending actions
- attachments
- bookmarks
- whiteboard

API:

- `GET /api/v1/app/chats/:id`
- `GET /api/v1/app/chats/:id/messages`
- `POST /api/v1/app/chats/:id/message`
- `POST /api/v1/app/chats/:id/stop`
- `POST /api/v1/app/chats/:id/refresh`
- `POST /api/v1/app/chats/:id/reset`
- proposal/pending-action command endpoints
- attachment endpoints
- whiteboard endpoints can be adapted from existing JSON controller

Realtime:

- `chat.message.appended`
- `chat.message.updated`
- `chat.controls.updated`
- `chat.header.updated`
- `chat.whiteboard.updated`
- `chat.turn.finished`

UI concerns:

- Replace Stimulus chat layout controllers with React layout state.
- Keep desktop split-pane and mobile tabs.
- Keep Excalidraw as React component directly instead of mounting it
  through Stimulus.
- Stream/apply new messages without jumping scroll when the operator
  is reading history.
- Preserve draft compose text across reconnects and route changes.

Acceptance:

- active chat can stream messages and tool cards without Turbo
- whiteboard conflict behavior matches existing versioned PATCH model
- proposal confirm/reject flows create the same records as today

### M9 - Repository and settings surfaces

Outcome: all regular operator CRUD/admin forms move to SPA.

Migrate:

- repositories index/show/new/edit
- repository GitHub issue browser and bulk actions
- scheduled tasks and cron templates
- credentials/settings/account documents
- tags
- invitations/users/password pages as appropriate

Notes:

- Sign-in, password reset, and GitHub App installation/callback pages
  may remain server-rendered longer. They are simple, unauthenticated
  or external-flow pages and do not benefit much from SPA behavior.
- Native HTML form validity needs a React equivalent. Prefer browser
  validity attributes plus a small shared form error summary component.

Acceptance:

- every mutating form has request specs and React tests
- GitHub issue single and bulk paths remain behaviorally identical
- file/document upload supports progress and failure states

### M10 - Retire Hotwire

Outcome: the app is a React SPA, not a hybrid.

- Remove route migration flags after all authenticated app routes are
  React-owned.
- Remove unused ERB templates and partials.
- Remove page-specific Stimulus controllers as their last uses vanish.
- Remove Turbo stream subscriptions and `broadcasts_refreshes` that no
  longer have HTML subscribers.
- Keep Action Cable, but only JSON app channels.
- Remove importmap if no remaining dependency needs it.
- Update AGENTS.md frontend notes to describe the React stack.
- Update `docs/turbo-audit.md` with a final note that it documents the
  retired architecture.
- Acceptance:
  - `rg "turbo_stream_from|turbo_frame_tag|data-controller"` shows only
    intentional leftovers
  - no migrated route renders ERB application body content
  - full test suite passes

## Data/API design rules

- API payloads are contracts. Do not mirror ActiveRecord columns
  blindly if the browser needs a smaller or more stable shape.
- Include capability booleans in detail payloads for command buttons:
  `can_approve`, `can_retry_step`, `can_rebase`, etc. Backend still
  checks the real AASM guards on mutation.
- Prefer command endpoints over client-side state transitions:
  `POST /jobs/:id/approve` returns the updated job or command result.
- Keep list endpoints compact. Detail pages can fetch nested workflow
  trees; dashboard lists should not.
- Use typed IDs consistently. If a payload references another resource,
  include `{ id, label, url }` where the UI naturally needs a link.
- Preserve URL-addressable state for filters, tabs, pages, and selected
  views.

## Testing strategy

Every migrated behavior needs tests.

- RSpec request specs for every new API endpoint.
- Channel specs for every new realtime event family.
- Vitest/React Testing Library for components, API hooks, and mutation
  states.
- Keep existing plain `node --test` Stimulus specs until those
  controllers are deleted.
- Add a small number of browser-level smoke tests once the SPA shell
  owns multiple routes:
  - sign in
  - navigate dashboard -> job -> repository
  - perform one safe mutation
  - receive one realtime update
- Do not shell out to real agents or hit real GitHub from tests.
  Reuse existing seams and WebMock/VCR patterns.

## Operational rollout

- Ship behind route-level flags.
- Enable first for admin user only.
- Log frontend API errors with route, query key, command name, and
  response code.
- Keep HTML fallback for each route until the React replacement has
  been used in production for at least one deploy cycle.
- For high-risk pages (`jobs/:id`, `chats/:id`), keep a visible
  "Open legacy view" link during the first rollout.
- During migration, deploys must still tolerate active RunJobs being
  killed; the SPA migration should not change worker behavior.

## Risks

- **Realtime fanout drift.** Old Turbo broadcasts and new JSON events
  can fall out of sync. Keep both calls adjacent in model/service code
  and add tests for critical paths.
- **Over-fetching job detail.** React invalidation can accidentally
  refetch huge nested payloads too often. Use append events for logs and
  split detail queries by panel when needed.
- **Client-side permission illusions.** Capability booleans improve UX
  but are not authorization. Every command endpoint must re-check
  policy and AASM guards.
- **Long hybrid period.** A half-migrated app has two UI stacks. Keep
  route ownership explicit and delete old code promptly after parity.
- **Forms regressions.** Rails form helpers currently handle lots of
  naming, CSRF, method override, and validation markup. React forms need
  shared primitives before migrating the form-heavy settings/repository
  pages.

## First PR

Do not start with a page rewrite. Start with the scaffolding PR:

1. Add Vite/React/TypeScript build pipeline.
2. Add `/api/v1/app/bootstrap`.
3. Add a tiny authenticated React route showing user email, admin flag,
   and revision.
4. Add Vitest plus one component test and one API-client test.
5. Update `bin/test` to include React tests.

That PR proves the deploy/test/tooling path without touching the
Hotwire surfaces that operators depend on.
