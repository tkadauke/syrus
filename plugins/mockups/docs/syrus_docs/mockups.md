# Mockups

Ships as the bundled `mockups` plugin, enabled by default. It gives
planning-mode chat agents a scratch area for building HTML/CSS/JS sketches
(`show_preview`, `write_preview_file`, `edit_preview_file`, `close_preview`)
and makes the results first-class objects an operator can find later.

## Slugs

A published mockup gets a stable `MOCKUP-<id>` slug, the same shape as
`JOB-<id>` and `EPIC-<id>`. Republishing a panel updates the same mockup rather
than creating another, so the slug survives an agent iterating on it. Both the
slug and a bare id resolve: `/mockups/MOCKUP-12` and `/mockups/12` are the same
page.

## The Mockups page

A **Mockups** entry in the primary sidebar opens a filter-bar-searchable list
(`/mockups`). Selecting one opens it in a side panel beside the list rather
than navigating away, so a filtered list stays put while you look through it.

Filter chips: `title`, `created_at`, `updated_at`. The bar uses the same chip
AST and `q` parameter as every other filtered list, and the applied filter is
returned with the results so the bar renders what is actually in effect.

Visibility: a mockup is visible to whoever can see the preview panel behind it,
which is the panel's own rule (you can see a panel if you can see its chat) —
not a second, looser rule.

## Relationship to preview panels

`PreviewPanel` and `PreviewPanelVersion` stay **core**. The panel is a generic
multi-format viewer — html, markdown, pdf, image — that other features render
into, and the mockups plugin is one of its clients rather than its owner.

Two core seams make that work:

* **`preview_panel_viewer`** — a plugin can teach the panel a content kind core
  does not know (`{ kind:, extensions: [], content_types: [] }`). Core's
  built-in kinds win, so a plugin extends the set rather than reinterpreting a
  file core already renders; an unrecognised kind falls back to source text.
* **`/api/v1/app/preview_panels/:id`** (`show`, `files`, `export`, `token`) —
  panel content addressed independently of the chat it was opened in, so a page
  outside chat can render one without inventing its own file serving. Scoped by
  `PreviewPanel.accessible_to`.

## Disabling

Turning the plugin off from Admin -> Plugins stops new mockups being recorded
and removes the page, nav entry and chat tools. Mockups already published are
kept, and the panels behind them are core and unaffected. Deleting a chat or a
user removes their mockup index entries, since the panel content goes with them.
