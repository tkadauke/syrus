# Frontend

Use these rules for the Rails-hosted React application, shared interaction patterns, routing, and visual consistency.

- **Detail pages graduate to tabs when sections are peer workflows.** Keep a
  detail page as one scrolling page when its content is a short, linear read
  or when a "tab" would only duplicate a single overview. Use shared underline
  tabs once the page has multiple peer workspaces operators revisit
  independently -- for example summary, review, workflows, timeline,
  attachments, artifacts, and source. Repository-like pseudo-tabs are only
  warranted when they route to distinct subpages; otherwise prefer normal
  sections on the detail page.
- **A plugin sidebar page's `paths` is still the whole contract on the React
  side.** `config/routes.rb`'s blanket `get "*path", to: "spa#show"` route
  (see below) makes Rails-side reachability unconditional, so a plugin no
  longer needs to declare anything for a hard reload to reach `spa#show`. What
  `paths` still drives is React's OWN client-side route table
  (`usePluginSidebarPaths` in `app/frontend/pluginSidebarPages.tsx`): a page
  whose component branches on `useParams().id` must declare the detail path
  (`["/design_docs", "/design_docs/:id"]`), or client-side navigation to it
  renders nothing, because React has no route for it — the failure is silent,
  because Rails happily served the shell. `spec/architecture/plugin_sidebar_page_routing_spec.rb`
  guards this. The host used to run a separate, narrower
  `repositories/:repository_id/plugin/*path` route
  (`PluginRouteResolver.repo_page_tab_route?`) gating this specifically to
  paths a `repo_page_tab` provider declared; that route was folded into the
  blanket wildcard too, since the constraint no longer decided anything the
  wildcard didn't already serve.
- **SPA routing is derived, not duplicated.** `config/routes.rb` ends with
  `get "*path", to: "spa#show", constraints: ->(req) { !req.path.start_with?("/api", "/rails") }, format: false`
  — every path `app/frontend/routes/App.tsx` (and any nested route file it
  references) owns reaches `spa#show` automatically, declared or not, so a
  hard reload or direct navigation never 404s just because someone forgot to
  hand-write a matching Rails route. This retired the ~90-line hand-written
  `spa#show` list this file used to require in the same PR as a new React
  route; see `spec/requests/spa_spec.rb`'s "routes every React app route"
  example. `/api` is excluded so an unmatched API call still gets a JSON 404;
  `/rails` is excluded because Active Storage, Action Mailbox, and other
  Railtie-owned GET routes live in gem `config/routes.rb` files Rails loads
  AFTER this one (`Rails.application.routes_reloader.paths`), so they land
  BEHIND the wildcard in the final route set rather than in front of it — the
  wildcard would otherwise swallow blob downloads and the mailbox health
  check instead of losing to them "by declaration order" the way every
  same-file route does. A named route (`as:`) is still worth keeping when a
  Ruby `_path`/`_url` helper is actually called somewhere (dashboard payloads,
  job claims, repository summaries, mailer templates, redirects) — grep for a
  real call before adding or removing one, since a coincidentally-matching
  JSON payload field name is not a caller.
- **Brand palette (terracotta).** The product accent is the terracotta of the
  winged-stylus brand mark (`#b6492e` at 600). `config/design_tokens/terracotta.json`
  is the single shared source for the scale — `config/tailwind.config.js`
  `require`s it directly and remaps Tailwind's `blue` scale onto the same
  values, so legacy `*-blue-*` utilities render the brand accent without a
  repo-wide rename. Use raw `terracotta-*`/`blue-*` accent utilities only for
  pre-auth web surfaces and desktop fixed-brand surfaces; authenticated in-app
  UI must use semantic theme tokens (`bg-brand`, `text-brand`, `border-brand`,
  `focus:ring-brand`, etc.) so it follows the signed-in user's selected theme.
  The desktop app's
  `@theme` block in `desktop/src/styles.css` imports a generated CSS partial
  (`desktop/src/styles/brand-tokens.generated.css`) instead of hand-copying
  the values a second time; after editing the JSON, regenerate it with
  `bin/generate-brand-tokens` (never hand-edit the generated file).
  `spec/desktop/brand_palette_spec.rb` validates both consumers against the
  shared JSON and fails if the generated file drifts. Don't reintroduce raw
  blue hexes for accents; semantically-blue user choices (annotation pen
  colors, tag label colors) are the exception and stay blue.
- **GitHub identifiers are links.** Whenever the UI renders a GitHub issue
  or pull request identifier (`#123`, `PR #123`, `owner/repo#123`), make it
  clickable to the matching GitHub page when a URL can be derived. Plain
  identifiers are only acceptable when the target is genuinely unknown.
- **Form validation UI** — React forms should use native validity
  attributes plus route-local error rendering.
- **Toolbar dropdown controls** — interactive toolbar controls that offer a small
  set of choices (like chat mode, model, or effort) use a custom button+listbox
  pattern, not a native `<select>`. The pattern is: a `<button>` with
  `aria-haspopup="listbox"` and `aria-expanded`, paired with an absolutely
  positioned `<div role="listbox">` containing `<button role="option">` items.
  Use `useRef` for the button and dropdown, and a `pointerdown` listener in a
  `useEffect` to close on outside clicks. See `ChatModeSelector`,
  `ChatModelSelector`, and `ChatEffortSelector` in `Compose.tsx` for the
  canonical implementation. Native `<select>` is only for form fields (settings
  pages, edit forms) where browser-native styling and keyboard navigation are
  sufficient.
- **Close icons** — React close/dismiss/remove controls should render the
  shared `CloseIcon` component (`app/frontend/components/CloseIcon.tsx`),
  not a literal `x` or `×` text node. Keep the accessible label explicit
  (`Dismiss notification`, `Close`, `Remove <thing>`, etc.) and size the icon
  with the component's `className` prop.
- **Pagination standard** — all paginated list views use the same UI:
  "Showing X–Y of Z" counter on the left; bordered pill buttons
  (`px-3 py-1 border border-gray-300 rounded hover:bg-gray-50`) for
  Previous/Next on the right with `gap-2` between them; disabled
  direction rendered as a grayed `<span>` with `border-gray-200
  text-gray-300` (never hidden). Wrapper: `flex items-center
  justify-between text-sm text-gray-600`. The controller exposes
  `@total_<collection>` and reads `PER_PAGE` from the controller constant;
  the view computes `first_item`/`last_item` inline. Only show the
  pagination block when `total_pages > 1`.
