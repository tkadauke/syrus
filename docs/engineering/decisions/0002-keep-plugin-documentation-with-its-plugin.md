---
id: ADR-0002
title: Keep plugin-owned documentation with its plugin
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0002: Keep plugin-owned documentation with its plugin

## Context

Bundled plugins are optional and must remain removable. Keeping a plugin's
operator documentation in core leaves stale traces, makes core depend on plugin
concepts, and separates behavior from its owner. The documentation search path
already discovers canonical documents contributed by enabled plugins.

## Decision

Documentation whose subject is a plugin lives under
`plugins/<name>/docs/syrus_docs/`. Core documentation may describe the plugin
system and link to plugin-owned material, but it does not copy a plugin's
documentation into `config/syrus_docs/` or the engineering hierarchy.

## Consequences

Removing a plugin removes its implementation and documentation together.
Plugin changes update their colocated docs in the same pull request. Shared
plugin contracts remain documented in core, while search and navigation must
include enabled plugin documentation without requiring copied pages.

## Evidence

- [Documentation policy](../conventions/documentation-policy.md)
- [Plugin architecture](../architecture/plugins.md)
- [Plugin documentation placement contract](../../../spec/architecture/plugin_docs_live_in_plugins_spec.rb)
- [Operator documentation search](../../../app/services/mcp/tools/search_syrus_docs_tool.rb)
