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

The Go client under `cli/` and Electron shell under `desktop/` are independent
clients of the same app API. They do not share the browser component tree.
Terminal and desktop behavior, authentication, and release rules are in
[CLI and desktop conventions](../conventions/cli-and-desktop.md).
