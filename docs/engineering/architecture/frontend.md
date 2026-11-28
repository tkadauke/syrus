# Frontend surfaces

Rails exposes authenticated JSON APIs and SPA shell routes. React under
`app/frontend/` owns browser routing, data fetching through TanStack Query,
live updates, and interaction state. When a new authenticated page is added,
both the Rails shell route and React route/navigation are required.

Shared UI contracts live in reusable components rather than page-local copies:
the Filters AST and `FilterBar` support searchable surfaces; SmartFolder-backed
screens persist the same effective filter; shared Markdown, tables, modals,
diffs, and chat message cards define cross-product behavior. User-visible copy
is localized with i18next. Detailed rules are in
[Frontend conventions](../conventions/frontend.md) and
[Localization](../conventions/localization.md).

Solid Cable events invalidate or update query state; API payload builders under
`app/services/app/` shape browser responses. The route and component inventory
is in [Frontend and plugins](../maps/frontend-and-plugins.md).

## Startup download and lazy chunks

Startup downloads only the shell: `main.tsx`, `AppChromeV2` with its sidebar,
the auth pages, and the dashboard (the signed-in root). Every other core route
is a lazy chunk declared once in `app/frontend/routes/routeChunks.ts` and
rendered through `lazyRoute` inside a `RouteSuspense` boundary with a stable
loading state. `main.tsx` starts the current URL's route chunk before the first
render (`preloadRouteChunkForPath`), so it downloads alongside startup rather
than after it.

Built-in plugin contributions that consumers read synchronously -- tool cards,
chat message and artifact renderers, provider connect panels, runtime session
views -- are registered by one `builtInPlugin<Kind>.ts` file per kind, which
only that kind's consumer imports. They, and the chat infrastructure tool
cards share, arrive with the first route that renders them and are registered
before its first frame, so a collapsed tool-card header never renders
differently on first paint. Startup imports `builtInPluginContributions.ts`,
which registers loaders only.

After the first commit (`react_commit`), `app/frontend/lib/chunkWarmup.ts`
fetches the remaining lazy chunks in the background: one at a time, when the
browser is idle, core product routes first, then plugin contributions, then
plugin routes, then admin pages (admins only). A chunk something on screen is
waiting for loads at once and pauses the queue until it settles. Warm-up stays
off on save-data or 2g connections and waits while the tab is hidden. Every
caller shares one promise per chunk, so a navigation after warm-up requests
nothing new. A failed background load stops warm-up without reloading;
`staleChunkRecovery` reloads once per asset revision only for a load something
is waiting on, and a lazy route keeps its loading state through that reload
instead of rendering blank.

`bin/check-frontend-bundle-size` (run by CI after `npm run build`) budgets the
gzipped startup graph -- the entry plus every chunk it statically imports --
and fails when a lazily loaded module becomes statically reachable from the
entry.

The Go client under `cli/` and Electron shell under `desktop/` are independent
clients of the same app API. They do not share the browser component tree.
Terminal and desktop behavior, authentication, and release rules are in
[CLI and desktop conventions](../conventions/cli-and-desktop.md).
