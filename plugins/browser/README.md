# Browser

Browser gives workflow agents a constrained Playwright browser for visual review and preview validation. Agents can navigate, click, fill forms, capture screenshots, and submit visual artifacts while Syrus restricts navigation to the step's own loopback preview.

The plugin is designed for UI work where code review alone is not enough. It keeps browser automation auditable and local to the workflow so agents can inspect visible behavior without gaining arbitrary network access.

## What It Adds

- A workflow MCP tool set backed by Playwright.
- Screenshot capture and image-diff artifact rendering.
- Browser actions used by the `visual_review` workflow step.

## Safety Model

Browser navigation is scoped to loopback preview URLs. The browser should validate the app under review, not browse arbitrary external sites or perform unrelated network activity.

## Service Behavior

Browser drives `@playwright/mcp` either as a per-Run stdio subprocess bundled into the worker image, or, when Plugin Runtime is enabled and a Browser service container is registered and healthy, as a shared container-backed Plugin Runtime service reached over streamable HTTP MCP. Which one applies is decided per session and needs no configuration: Syrus falls back to the stdio subprocess automatically whenever the service is unavailable. See `docs/syrus_docs/browser.md` for the full service boundary and `docs/syrus_docs/plugin_runtime.md` for how to inspect, restart, and read logs for the service through the Plugin Services admin page.

## When To Enable

Enable this plugin when repositories use previews or visual review. Disable it on installations that only perform non-visual backend work.
