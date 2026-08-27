# Tailscale

Tailscale registers a Syrus instance as a Tailscale node so operators can reach it over a private tailnet. It manages lifecycle callbacks, status reporting, and the admin page needed to inspect connectivity.

Enable it when an installation should be reachable without exposing Syrus directly on the public internet. It is disabled by default because it requires a Tailscale auth key and network policy decisions outside Syrus.

## What It Adds

- Plugin lifecycle callbacks that manage Tailscale state.
- Admin and REST status endpoints.
- Optional admin UI for connection state.

## When To Enable

Enable Tailscale for self-hosted deployments that use a tailnet as the access layer. Disable it for public deployments or environments where networking is handled outside Syrus.

## Operational Notes

The plugin expects Tailscale credentials to be provided through environment-backed configuration. Operators remain responsible for tailnet ACLs and device policy.
