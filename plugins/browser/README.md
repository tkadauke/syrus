# Browser

Browser gives workflow agents a constrained Playwright browser for visual review and preview validation. Agents can navigate, click, fill forms, capture screenshots, and submit visual artifacts while Syrus restricts navigation to the step's own loopback preview.

The plugin is designed for UI work where code review alone is not enough. It keeps browser automation auditable and local to the workflow so agents can inspect visible behavior without gaining arbitrary network access.

## What It Adds

- A workflow MCP tool set backed by Playwright.
- Screenshot capture and image-diff artifact rendering.
- Browser actions used by the `visual_review` workflow step.

## Safety Model

Browser navigation is scoped to loopback preview URLs. The browser should validate the app under review, not browse arbitrary external sites or perform unrelated network activity.

## When To Enable

Enable this plugin when repositories use previews or visual review. Disable it on installations that only perform non-visual backend work.
