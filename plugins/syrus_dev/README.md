# Syrus Dev

Syrus Dev contains tooling that is useful when developing Syrus itself: performance diagnostics, operational logs, admin observability pages, and workflow MCP helpers that expose Syrus runtime data to Syrus-development jobs.

Keep this plugin disabled on ordinary installations unless operators explicitly want Syrus-internal diagnostics. It is not a general admin plugin; it exists to make Syrus better at building and debugging Syrus.

## What It Adds

- Admin performance and operational-log pages.
- Admin API endpoints for performance diagnostics and operational logs.
- Workflow MCP tools for reading sanitized Syrus runtime diagnostics.

## When To Enable

Enable Syrus Dev on instances used to develop or operate Syrus itself. Keep it disabled for normal customer or project installations where Syrus-internal debugging would add noise.

## Operational Notes

Some surfaces expose implementation details about Syrus. They are useful for agents working on Syrus, but they should not be treated as generic product features.
