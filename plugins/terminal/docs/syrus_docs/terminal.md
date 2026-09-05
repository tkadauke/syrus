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

## Limitations

- One terminal session per workflow run.
- Sessions do not persist across worker restarts.
- The relay is not exposed through public ingress; it requires direct network access between web and worker pods/containers.
- Only available while a Run is in `running` state. Completed or failed runs do not have an active PTY.
