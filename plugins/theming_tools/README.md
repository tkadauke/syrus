# Theming Tools

Theming Tools gives the Syrus Chat agent a complete custom-theme tool set. It can draft a candidate theme and open it against the real Style Guide, validate persisted palettes for WCAG AA contrast, install a theme, and list, update, or delete the calling user's custom themes.

The underlying `Theme` model stays in core (same precedent as `WhiteboardSnapshot` for `whiteboard`) — this plugin owns the chat MCP tools and the broadcast wiring that opens the preview modal.

## What It Adds

- `preview_theme`, which upserts a per-user draft and reports non-blocking contrast warnings while iterating.
- `install_theme`, which installs an existing selectable theme or a complete new theme and rejects WCAG AA contrast failures.
- `list_user_themes`, `update_user_theme`, and `delete_user_theme`, which are scoped to custom themes owned by the calling user. Updates revalidate contrast; deleting the active theme first restores the default built-in theme.
- An app-event broadcast that opens a live Style Guide preview modal in the chat UI.

## When To Enable

Enable Theming Tools when chat agents should be able to design, validate, install, and manage custom themes with a user. Keep it disabled on installations that do not want agent-assisted theming.

## Operational Notes

`preview_theme` is safe to call repeatedly: each call updates the same draft row and may temporarily contain low-contrast choices so an agent can iterate. `install_theme` and `update_user_theme` are the hard persistence boundaries and reject failing text/surface and status-tone contrast pairs. All CRUD tools enforce ownership and do not expose or mutate another user's custom themes or built-in themes.
