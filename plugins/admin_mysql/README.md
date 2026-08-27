# Admin MySQL

Admin MySQL exposes the live state of a Syrus instance's MySQL server: process list, connection pressure, slow-log configuration, statement digests, and targeted query termination. It is intentionally operator-facing and disabled by default because it surfaces database internals and control actions.

Use this plugin when a deployment runs against MySQL and needs real-time production diagnosis without shelling into the database pod. SQLite-backed installations do not need it.

## What It Adds

- Admin pages for current MySQL process state, connection limits, slow-log settings, statement digests, and live query inspection.
- Admin API endpoints for the same live MySQL state.
- Workflow and chat MCP tools that let authorized Syrus-development agents inspect MySQL pressure and kill a bad query when appropriate.

## When To Enable

Enable Admin MySQL on production or staging instances backed by MySQL where operators need to debug database pressure from inside Syrus. Keep it disabled on SQLite instances or on installations where database inspection should stay outside the app.

## Operational Notes

The plugin reads live database state and can terminate queries, so access should stay admin-only. Some panels require MySQL grants such as `PROCESS` or selective `performance_schema` reads; the UI reports missing permissions instead of assuming they are available.
