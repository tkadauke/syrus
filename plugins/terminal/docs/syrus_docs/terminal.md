# Terminal

The terminal gives operators interactive PTY access to the agent's workspace during a workflow run. It ships as the `terminal` plugin, disabled by default.

## Enabling

Enable it from Admin -> Plugins, or:

```ruby
PluginRecord.find_by(name: "terminal").update(enabled: true)
```

Once enabled, a Terminal entry appears in the sidebar (badged with the number of open sessions) and an "Open terminal in workspace" button appears on each workflow card on the Job page. Disabling the plugin withholds both, and its API routes return `plugin_disabled`; the Action Cable channel rejects new subscriptions.

The plugin owns `Terminal::Session` (table `terminal_sessions`), `TerminalChannel`, `TerminalSessionJob`, `Terminal::Relay`, its controller, and the SPA route. It reaches the sidebar through `:sidebar_page` and the Job page through the `job.workflow.actions` `:ui_slot`.

## Architecture

The terminal relay is a TCP server that the worker-side PTY session advertises. The web container connects to it through Docker internal DNS or Kubernetes CNI networking.

### Relay address resolution

`SYRUS_TERMINAL_HOST` controls where the web container looks for the relay:

| Environment | Setting |
|---|---|
| Bare-metal / local dev | Leave blank; `Terminal::Relay` defaults to `127.0.0.1` |
| Docker Compose | Set to the worker service name (e.g., `worker`) so web reaches it via Docker DNS |
| Kubernetes | Set `SYRUS_TERMINAL_HOST` from the Downward API field `status.podIP` on worker pods; web pods connect directly over the CNI network |

Traefik and public ingress are not involved — the relay is internal only.

### Session lifecycle

- Sessions start when an operator opens the terminal panel.
- Sessions survive browser navigation; the PTY lives in the worker process until it exits or the operator kills it.
- Sessions die on worker restart or redeploy; there is no wall-clock idle timeout.
- Security is enforced by a per-session auth token exchanged over the relay socket after the browser's authenticated Action Cable subscription is authorized.

## What operators can do

The terminal gives shell access to the workflow workspace (a shallow clone of the repository). Operators can inspect files, run commands, check git state, or debug a stuck agent. Changes made in the terminal are visible to the agent if it is still running.

## Admin API

`/api/v1/admin/terminal_sessions` gives bearer-token admin API clients the same
inspect-and-kill surface the app API gives an individual signed-in user, but
across every user — the same shape as core's `/api/v1/admin/processes`.

- `GET /api/v1/admin/terminal_sessions` — list sessions, filterable by
  `?state=running|finished`, `?user=<email substring>`, and
  `?hostname=<relay host>` (matched against the host portion of
  `relay_address`). Supports `?page`/`?per` (default 50, max 100).
- `GET /api/v1/admin/terminal_sessions/:id` — one session's detail.
- `POST /api/v1/admin/terminal_sessions/:id/kill` — kill the session. This is
  the same write path (`Terminal::KillSession`) the app API's kill/destroy
  actions use: it flips the session to finished/killed so the worker-side
  Relay's kill-poll observes it and sends `SIGTERM` to the PTY.

Session payloads add `state`, `hostname`, `age_s`, and an owning `user`
summary on top of the app API's fields; they never include `auth_token`. With
the plugin disabled, every endpoint answers `plugin_disabled` like the rest of
the plugin's routes.

## Limitations

- One terminal session per workflow run.
- Sessions do not persist across worker restarts.
- The relay is not exposed through public ingress; it requires direct network access between web and worker pods/containers.
- Only available while a Run is in `running` state. Completed or failed runs do not have an active PTY.
