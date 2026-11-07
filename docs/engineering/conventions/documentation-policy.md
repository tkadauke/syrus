# Documentation policy

Use these rules to keep public, operator, plugin, and repository guidance in their owning locations.

- **Public website/docs stay current.** Product-facing behavior changes
  must update `website/` in the same PR. If a change affects what Syrus
  is, why someone would use it, how to get started, a workflow, a feature,
  configuration, credentials, operations, schedules, chats/direct Jobs,
  troubleshooting, or an API surface, update the matching page under
  `website/src/app/` or `website/src/content/docs/`. Prefer updating an
  existing page over adding a parallel one; if the navigation contract
  changes, update `website/README.md` too. PRs that add product behavior
  while leaving the public docs stale are incomplete.
- **A plugin's docs live in the plugin.** Full documentation for a bundled
  plugin belongs at `plugins/<name>/docs/syrus_docs/*.md`, not in
  `config/syrus_docs/`, so deleting the plugin directory removes its docs too.
  Core docs may still mention a plugin; a doc whose whole subject is one plugin
  may not live in core. `search_syrus_docs` reads core's docs plus every
  *enabled* plugin's, and for an installed-but-disabled plugin emits one teaser
  generated from the manifest's `long_description` (no separate teaser file to
  drift), leading with the fact that it is disabled. Guarded by
  `spec/architecture/plugin_docs_live_in_plugins_spec.rb`.
- **Feature documentation is mandatory.** When adding or changing any
  operator-facing feature — configuration keys, feature flags, `AppSetting`
  columns, new step kinds, new trigger kinds, or changes to existing behavior
  — update the matching file under `config/syrus_docs/` in the same PR. New
  features that have no existing doc file should create one following the
  format in the existing files. PRs that add operator-facing behavior while
  leaving the docs stale are incomplete, same as public website docs.
- **Website/docs audit.** If no website/docs update is needed, the PR body
  must say why so reviewers can audit the call. `AGENTS.md` is a symlink to
  `CLAUDE.md`; preserve that relationship and edit the shared guidance through
  `CLAUDE.md`.
- **Feature flag descriptions are timeless.** `config/features.yml`
  descriptions must not reference PR numbers, issue numbers, or phrases like
  "Introduced in PR #123." or "Added in #456." That information is in git
  history; in the YAML it becomes stale and misleading once the flag is widely
  deployed. Describe only what the flag does and any operator requirements
  (e.g. "Requires a Gemini API key.").
