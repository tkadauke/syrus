# Whiteboard

Whiteboard adds a shared Excalidraw canvas to chat workspaces and exposes drawing tools to chat agents. Operators and agents can sketch flows, annotate ideas, save snapshots, and revisit visual state as part of a planning session.

Use it for design and architecture discussions where text is not enough. The plugin stores whiteboard state per chat and keeps the drawing surface separate from repository code.

## What It Adds

- A chat workspace tab for the shared whiteboard.
- MCP drawing, move, delete, read, save, clear, and load tools.
- REST endpoints for whiteboard state and snapshots.

## When To Enable

Enable Whiteboard when planning chats benefit from diagrams or rough UI sketches. Disable it on minimal installations that want chat to stay text-only.

## Operational Notes

Whiteboard snapshots are collaboration artifacts, not source files. Important implementation decisions should still be captured in jobs, epics, or repository docs.
