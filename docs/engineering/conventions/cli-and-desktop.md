# CLI and desktop

Use these rules for the Go CLI and the Electron desktop application.

- **Go CLI** lives under `cli/` and talks to the app-scoped JSON API
  (`/api/v1/app/*`). Keep CLI commands, API serializers/controllers, and
  `website/src/content/docs/api.md` aligned when changing terminal-visible
  behavior; `cli/.syrus.yml` owns the core CLI project metadata, while the
  root `.syrus.yml` keeps an executable Go-workspace backstop for core CLI
  paths, plugin-owned CLI modules, and release/desktop packaging paths until
  nested grader targets run directly. For local broad validation, run
  `go test $(go list -m -f '{{.Dir}}/...')` from the repo root,
  which covers the CLI module and every plugin-owned CLI module in `go.work`. The CLI covers
  chat plus Job, Epic, repository, schedule, checkout, inbox, test-plan,
  approval, and identity workflows; repo-aware commands should detect `origin`,
  scope to that repo by default, and refuse checkout changes when the local repo
  mismatches. Job and Epic identifiers are accepted as numeric IDs, `JOB-N`/`EPIC-N`
  prefixes, or human-readable slugs; use the `JobEpicRefFinder` concern
  (included in both app and admin base controllers) to resolve them server-side.
  Commands a bundled plugin owns live in that plugin's own Go module under
  `plugins/<name>/cli` and are wired into the root command in `cli/cmd/root.go`
  (`go.work` joins the modules). Go has no usable dynamic plugin loading for a
  single static binary, so they are compiled in rather than loaded; there is no
  runtime gating, because a disabled plugin's API routes already answer with a
  `plugin_disabled` error. A plugin module cannot reach `cli/internal/...`, so
  the helpers it may use are exported from `cli/pkg/cliplugin` (and
  `cliplugintest` for the test harness) -- keep that surface small and add to it
  deliberately, since it is API for plugin modules.
- **Desktop app** lives under `desktop/` as a separate Electron + React + Vite
  app. It uses Tailwind too, but it does not share the Rails web app's compiled
  CSS or components at runtime. Keep the desktop UI visually aligned with the
  web app's primitives: compact rows, restrained icon buttons, bordered white
  panels, terracotta primary actions (the brand accent, `#b6492e` at 600 —
  see the palette note below), emerald success pills, red failure/error
  pills, and slate/gray neutral text. Avoid broad element styling in
  `desktop/src/styles.css` (especially global `button` rules) because the tray
  surface relies on small, explicit controls. Prefer explicit local primitives
  such as `primary-button`, `secondary-button`, `icon-button`, and status pills.
  Ships on macOS (universal arm64+x64 DMG) and Windows (x64-only installer;
  Windows on ARM runs via built-in x64 emulation). Test desktop changes with
  `npm --prefix desktop run typecheck`, `npm --prefix desktop run build:renderer`,
  and `npm --prefix desktop run build:main`; run the desktop RSpec startup spec
  when Electron main/preload code changes. Local backend updates stream their
  progress over the existing shell-notice bridge: `updateBackend` parses the
  installer's `--json` NDJSON into `ShellNoticeState.backendUpdate` (phase
  `starting`/`downloading`/`migrating` + pull percent + `outage`), bounded by
  a 30-minute deadline that kills a wedged installer tree; the SPA renders it
  as a sidebar notice for the whole update, and `useBackendOutage` (in
  `useBackendUpdate.ts`, with a 5-minute staleness fuse) is the SPA's single
  choke point for "the backend is deliberately unreachable" — surfaces that
  read failed connectivity/credential checks must gate on it instead of
  rendering the unconfigured default ("GitHub not connected"). `outage` is
  true only from container recreation (`stack_up`) on; during the image pull
  the old backend still serves and nothing is gated.
