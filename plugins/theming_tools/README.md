# Theming Tools

Theming Tools gives the Syrus Chat agent a `preview_theme` tool: it can draft a candidate color theme and pop it open for the user against the real Style Guide page, so token choices are judged on actual `Button`/`Input`/`Card`/etc. components instead of a recreated mockup.

The underlying `Theme` model stays in core (same precedent as `WhiteboardSnapshot` for `whiteboard_tools`) — this plugin only owns the `preview_theme` MCP tool and the broadcast wiring that opens the preview modal.

## What It Adds

- A `preview_theme` chat MCP tool that upserts a draft `Theme` row for the calling user.
- An app-event broadcast that opens a live Style Guide preview modal in the chat UI.

## When To Enable

Enable Theming Tools when chat agents should be able to design and preview custom color themes with a user. Keep it disabled on installations that don't want agent-assisted theming, or until `install_theme` and full theme CRUD land in a follow-up.

## Operational Notes

`preview_theme` is safe to call repeatedly — each call updates the same draft theme in place instead of creating a new row. It does not persist a theme as installable; that lands with `install_theme` in a follow-up plugin update, alongside contrast validation.
