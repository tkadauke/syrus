# Terminal

The terminal feature gives operators interactive PTY access to the agent's workspace during a workflow run. It is a labs feature, disabled by default.

## Enabling

```ruby
Feature.find_by(slug: 'terminal').update(enabled: true)
```

Once enabled, a Terminal button appears on the Run detail page while a workflow is active.

## Architecture

The terminal relay is a TCP server that the worker-side PTY session advertises. The web container connects to it through Docker internal DNS or Kubernetes CNI networking.

### Relay address resolution

`SYRUS_TERMINAL_HOST` controls where the web container looks for the relay:

| Environment | Setting |
|---|---|
| Bare-metal / local dev | Leave blank; `TerminalRelay` defaults to `127.0.0.1` |
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
