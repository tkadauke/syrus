---
title: Plugins
description: How Syrus plugins extend UI, tools, prompts, graders, previews, and integrations.
---

# Plugins

Plugins are installed extension bundles. Installing a plugin makes its code
available after restart; enabling a plugin makes its surfaces visible and its
behavior active. In general, the plugin enable switch is the feature flag for
that plugin.

## What Plugins Can Add

Plugins can contribute:

- sidebar and admin navigation entries,
- repository tabs,
- React components bundled into the app,
- MCP tools for chat and workflow agents,
- prompt context injectors,
- typed artifact renderers,
- preview providers,
- prepare detectors,
- grader augmentors,
- CI log parsers,
- dependency-audit commands,
- affected-test analyzers,
- source integrations such as GitHub or Linear.

The core app should keep behavior that is required for Syrus to function.
Plugins should be things that can reasonably be disabled, replaced, or
distributed separately.

## Installed vs Enabled

Installed means the plugin's code, migrations, translations, and frontend
assets are present. Enabled means Syrus uses the plugin at runtime. This lets
operators install a plugin during deployment but turn it on only for the
repositories or users that need it.

Some plugins may be non-disableable because they provide core surfaces for a
given distribution. Most should be disableable.

## Plugin Data

Plugins can own database tables. When they do, table names and model
namespaces should make ownership obvious, such as `linear_tickets` for
`Linear::Ticket`. Plugin migrations should avoid surprising global changes and
should follow the same no-foreign-key policy as the rest of Syrus.

## MCP Tools

Workflow and chat agents see tools through toolsets. A plugin should expose a
toolset as the registration point, but individual tools should stay small and
separately testable. Good tools have narrow inputs, clear side effects, and
structured results.

Tool usage is logged so operators can see which tools are active, failing, or
worth consolidating.

## UI Contributions

Admin and repository pages are discovered from plugin declarations. Disabling a
plugin hides those pages, but the compiled JavaScript can remain part of the
app bundle. This keeps runtime enable/disable simple while still allowing
plugin pages to use normal React components.

## Dependencies

Plugins may depend on other plugins. If a dependency is disabled, Syrus should
warn or cascade-disable dependent plugins rather than exposing a broken UI
surface.

## Authoring Guidelines

Keep plugin boundaries crisp:

- put plugin-specific tests with the plugin,
- namespace plugin models,
- prefix plugin-owned tables,
- use extension points instead of monkey-patching core behavior,
- make runtime disablement leave the rest of Syrus usable.
