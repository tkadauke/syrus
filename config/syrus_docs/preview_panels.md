# Preview Panels

Preview panels let planning-mode chat agents build and show live HTML/CSS/JS
mockups, Markdown notes, PDFs, SVGs, and raster images in the chat sidebar.
They serve static files rather than a running application. A chat may have
several independently closeable panels.

Panels are private by default, which means they are visible to people who can
open the chat. An operator may explicitly make a panel public and copy its URL.
Public panels are visible to anyone with that URL.

The bundled `mockups` plugin provides these planning-mode tools:

- `show_preview(panel_id?, title, entry_file: "index.html")` creates an empty
  panel when no id is supplied. Write its files, then call `show_preview` with
  that id to publish a version. Repeated calls publish new versions without
  overwriting earlier ones.
- `write_preview_file(panel_id, path, content)` creates or replaces a scratch
  file for the panel.
- `edit_preview_file(panel_id, path, old_string, new_string, replace_all:)`
  edits a scratch file; `old_string` must be unique unless `replace_all` is set.
- `close_preview(panel_id)` closes the transient chat tab. A published mockup
  remains reachable through the returned `mockup_slug`.

Both file tools are jailed to the selected panel's scratch directory. Preview
panel tools are available only in planning-mode chats; Coding Mode and Local
Mode use their writable checkout tools instead.

Panel payloads include only the current version summary by default. The
standalone panel endpoint accepts `?include=versions` when a version picker
needs the complete history.

`show_preview` returns a `version_id`. Pass
`preview_panel_version:<version_id>` in `propose_job`'s `media` array to attach
that exact version to an implementation Job. The implementing agent receives
the source files as reference material.

Preview panels reuse `SYRUS_PREVIEW_BASE_DOMAIN`. See [Preview
Environments](preview_environments.md). Internal storage, proxy, authentication,
payload, exporter, and viewer-extension details live in [preview-panel
architecture](../../docs/engineering/architecture/preview-panels.md).
