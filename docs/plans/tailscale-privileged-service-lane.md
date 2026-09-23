# Tailscale Privileged Service Lane

## Status

Shipped. Items 1-4 of the Implementation Plan below (the Go privileged lane,
the Ruby `PrivilegedService`/`DesiredPrivilegedServices` wiring, the
Tailscale container image, and the Tailscale plugin migration off
`Tailscale::DaemonManager`) landed together, in the same change that removed
`docker-compose.yml`'s worker `cap_add`/`devices` block -- no dual-path
window where both the in-worker daemon and the container-backed service
could run at once. `plugin_runtime.md`'s "What the runtime manager refuses"
section (item 5) describes the shipped lane, including its own note (added in
the docs/tests follow-up below) that the lane is Compose-only.

A follow-up job closed out the operational documentation and test gaps this
plan deliberately left open: `plugins/tailscale/docs/syrus_docs/tailscale.md`
now has "Operator flows" (enable/disable/restart/status/missing-runtime/
service-unhealthy), "Admin API compatibility" (the two status routes are
unchanged), and "Upgrading from the worker-embedded daemon" (migration notes)
sections; `website/src/content/docs/troubleshooting.md` and
`deployment/docker-compose.md` cover the same flows for the public docs
audience; and `plugins/tailscale/spec/requests/api/v1/app/admin/tailscale_plugin_services_spec.rb`
exercises the real (non-fake) privileged-lane wiring through Plugin Runtime's
shared Admin → Plugin Services API -- list/status, stop, start, restart,
missing runtime (plugin disabled and manager unreachable), and unhealthy.

Item 6's live-Compose verification (`bin/compose-up` against a real tailnet
with a real auth key) is still not something an unattended agent run can do
and remains for a human operator to confirm once, the same as before. The two
"Open questions" below are likewise still open -- this follow-up did not
attempt to resolve either.

## Context

Two facts, both already true in the source tree, create the problem this plan
resolves:

1. **Tailscale runs inside the generic worker today.**
   `Tailscale::DaemonManager` (`plugins/tailscale/app/services/tailscale/daemon_manager.rb`)
   `Process.spawn`s `tailscaled` directly inside the worker process, talks to
   it over a Unix socket at `/tmp/tailscaled.sock`, and keeps its state at
   `/tmp/tailscaled.state` — inside the worker's own ephemeral filesystem, so a
   worker restart re-registers the node as new rather than resuming its
   identity. Because of this, `docker-compose.yml`'s `worker` service carries
   `cap_add: [NET_ADMIN, NET_RAW]` and `devices: [/dev/net/tun:/dev/net/tun]`
   — a real Linux networking capability sitting on the same container that
   runs agent shell sessions.

2. **The shipped Plugin Runtime cannot express that, on purpose.** The
   `plugin_runtime:service` contract (`plugins/plugin_runtime/lib/plugin_runtime/service.rb`)
   and its wire format (`plugins/plugin_runtime/container/internal/spec/spec.go`)
   have no field for privileges, devices, host mounts, host networking, or
   published ports — not disabled, *absent*. `internal/docker/types.go`'s
   `HostConfig` says so directly: "Privileged, CapAdd, Devices, Binds, PidMode,
   IpcMode, UsernsMode, PortBindings and host networking are not fields of
   this struct. That is the enforcement, not a convention." The policy
   package's own doc comment states the goal explicitly: the worker holds the
   runtime manager's token and runs agents with shell access, so "the token
   must be assumed to leak," and the design goal is that holding it "buys
   nothing dangerous."

DOC-28 (Container-Backed Plugin Runtime) named Tailscale as its motivating
migration, but its shipped implementation is stricter than that draft
originally assumed. Its reality-update comment says plainly: Tailscale "needs
either a tightly allowlisted first-party privileged-service lane or another
special deployment path rather than the generic Plugin Runtime contract as
shipped." This plan picks between those two shapes and specifies the one it
picks in enough detail to build.

## The two shapes

### A. A tightly allowlisted, first-party privileged lane inside Plugin Runtime — chosen

The runtime manager gains a second, structurally separate request path that
only exists for a small, compiled-in table of known services — not a
generalized "privileged: true" field on the existing service spec, and not
something any plugin's manifest can opt into by shipping a provider class.

- A new Go package, `internal/privileged`, defines a `Definition` per known
  service: fixed image reference, fixed internal port, fixed `CapAdd`,
  fixed `Devices`, an optional fixed named volume, an optional healthcheck,
  and an explicit, small `AllowedEnvKeys` list. The only entry at launch is
  `tailscale`.
- A new, narrow request type — not `spec.Service` — carries just
  `{ "env": { "TS_AUTHKEY": "...", ... } }`, decoded with
  `DisallowUnknownFields()` the same way the existing `ensure` handler
  already refuses unknown fields. There is no `image`, `internal_port`,
  `volumes`, `devices`, or `cap_add` key for a caller to populate: the
  request cannot express them because the type has no field for them, the
  same enforcement `HostConfig` already relies on for the generic path.
- A new, separately named HTTP surface: `PUT /v1/privileged/{name}`. Every
  *other* operation — `GET .../services/{name}`, `POST .../stop`,
  `.../start`, `.../restart`, `GET .../logs` — is reused unchanged, because
  none of them accepts a payload that shapes a container. They act on
  whatever container the label lookup finds, privileged or not, which is
  already safe. Only the "create or replace" verb needs a privileged
  counterpart, because that is the only verb whose request body a caller
  controls.
- `manager.Manager` gains `EnsurePrivileged(ctx, name, env)`, sharing
  `create`'s volume/label/network plumbing but building its `HostConfig`
  from the compiled `Definition` — never from `env` — and adding `CapAdd`
  and `Devices` to `docker.HostConfig` (new fields, populated **only** from
  this one function). The generic `create()` path is untouched and still
  cannot reach those fields, because nothing feeds them into it. `Status`
  gains `Privileged bool`, read off a new `LabelPrivileged` container label,
  so the existing `List`/`Status` calls report it for free.
- On the Rails side, `PluginRuntime` gains a `plugin_runtime:privileged_service`
  extension point, duck-typed like `Service` (`privileged_service_name`,
  `privileged_env`) but collected by a `DesiredPrivilegedServices` class
  that filters candidates through a **hardcoded Ruby constant** —
  `PluginRuntime::FIRST_PARTY_PRIVILEGED_PLUGINS = %w[tailscale]` — before
  ever calling the client. This is deliberate defense in depth: the Go
  manager's `privileged.Registry` and this Ruby constant are two
  independently-maintained allowlists that do not derive from one another,
  so a mistake in either one alone (a stray manifest declaration on the
  Ruby side, a forgotten table entry on the Go side) fails closed instead
  of silently granting privilege.
- `Client` gains `ensure_privileged_service(name, env)`; `ManagedDriver#reconcile`
  calls it for privileged entries in the same tick as ordinary ones, writing
  to the same `StatusCache` keyed by service name.

Everything else about how a container-backed plugin is built, published, and
operated — image naming, `bin/publish-plugin-images`, version pinning to
`SYRUS_VERSION`, Compose vs. Kubernetes ("managed" vs. "external") mode,
health-check polling, log retrieval, volume listing — is reused exactly as it
exists for Git Mirror today. Nothing here is new *infrastructure*; it is one
new, narrow, structurally-isolated verb on infrastructure that already ships.

### B. A static Compose/Kubernetes Tailscale service, owned outside the manager

Tailscale becomes a service block declared directly in `docker-compose.yml`
(and documented as a Kubernetes manifest pattern for operators), the same way
`plugin-runtime` itself is a base-stack service rather than something the
manager starts. `cap_add`/`devices` live on that static block. The Rails
plugin never calls Docker at all, in any form: it only talks to the
container's small HTTP API over the project network (status, config
push) and treats it exactly like an `ExternalDriver`-mode service — a URL to
health-check and use if healthy, nothing to create or destroy. Turning
Tailscale on or off means an operator (or `install.sh`) changing a Compose
profile / `.env` flag and re-running `docker compose up -d`.

This gives the strongest possible isolation: the worker-held Plugin Runtime
token cannot touch the Tailscale container at all, under any circumstance,
because Rails never has a code path that asks the manager to create, replace,
or reconfigure it. That is strictly better containment than shape A.

It costs three things shape A gets for free today:

- **Self-serve enable breaks.** Right now, enabling the `tailscale` plugin in
  Admin → Plugins and saving an auth key is enough — `on_enable` starts the
  daemon within the same request cycle. Under shape B, enabling the plugin in
  the database does nothing until an operator (human, or `install.sh` on next
  run) materializes the Compose profile and restarts the stack. That is a
  real regression from the currently-shipped UX, not a neutral tradeoff.
- **Admin visibility has to be rebuilt from scratch.** Status, logs, restart,
  and stored-data listing for Git Mirror all come from the runtime manager's
  existing `/v1/services/*` surface and the shared `Admin::PluginServices`
  page. A statically-declared Compose service has none of that; giving an
  operator equivalent visibility means either building a second, parallel
  admin surface for exactly one plugin, or accepting that Tailscale has no
  live container status/log page at all (a regression from what Plugin
  Runtime already provides Git Mirror).
- **Kubernetes gets no help from this design at all.** Compose and
  Kubernetes need separate static manifests maintained by hand, whereas
  shape A's Kubernetes story is already solved: "external" mode already
  means "the operator deploys it themselves and gives Syrus a URL," which
  is exactly how a privileged Kubernetes DaemonSet with its own
  `NET_ADMIN`/TUN grant already has to work. Shape B does not change the
  Kubernetes side of this plan; it only changes Compose, and changes it in a
  way shape A's "external" path already covers for free.

Shape B is the right call if the working assumption is that a leaked
Plugin Runtime manager token is intolerable at any privilege level, however
narrow. That is not the working assumption here — see the security analysis
below — so shape B is rejected for now. It is worth re-opening if a future
privileged service is less containable than Tailscale (see Open Questions).

### Considered and rejected: generalizing the service spec with a `privileged: true` flag

Instead of a separate `Definition` table and a separate endpoint, the
generic `spec.Service` wire type could grow an optional `privileged: true`
field plus `cap_add`/`devices` fields, gated by a manager-side allowlist of
*plugin names* allowed to set it. Rejected: this reintroduces exactly the
shape the shipped policy package was built to avoid — a boolean somewhere in
a deserialized request that flips a container into a different security
class. It is one missed check away from being requestable by any plugin, and
every future contributor to `plugin_runtime:service` becomes a reviewer of
whether their own new field composes safely with `privileged: true`. A
compiled table with its own request type has none of that: adding a second
privileged service later is a Plugin Runtime *release*, reviewed as one,
never a runtime-configurable plugin declaration.

### Considered and rejected: moving `tailscaled` into the runtime manager's own container

The runtime manager is deliberately the one process in the stack holding the
Docker socket, and deliberately minimal (hand-written HTTP client instead of
the Docker SDK, distroless image, no shell) so that surface stays reviewable.
Giving that same container `NET_ADMIN`/`/dev/net/tun` as well would
concentrate two separate high-value capabilities — "can ask the daemon to
run anything approved" and "can manipulate network interfaces" — in one
process. Keeping them apart means compromising the manager image buys
container orchestration but not network capability, and compromising the
Tailscale image buys network capability but not the Docker socket.

## Why shape A

Shape A keeps every piece of already-shipped Plugin Runtime infrastructure
(admin page, image publishing/versioning, health polling, logs, Compose vs.
Kubernetes parity) and adds one narrow, auditable exception to "the manager
never expresses privilege." Shape B keeps the isolation property absolute
but throws away that infrastructure and regresses the enable UX the
Tailscale plugin already has today. The choice comes down to whether the
narrow exception is actually dangerous enough to justify the regression —
the next section argues it is not.

## Security analysis: does the invariant survive?

The requirement is that a worker-held manager token must not be able to
"request arbitrary privileged containers, devices, host mounts, host
networking, or published ports." Shape A satisfies "arbitrary" specifically
because none of those things is ever deserialized from a request on the new
path either:

- **Image**: fixed in `Definition`, not a request field. A caller cannot ask
  for a different image, digest, or registry.
- **Capabilities and devices**: fixed in `Definition`, populated into
  `HostConfig` only inside `EnsurePrivileged`, never from decoded JSON.
- **Host mounts, host networking, published ports**: absent from
  `docker.HostConfig` exactly as before; nothing in this plan adds them.
- **Which services are privileged at all**: a compiled Go map, not a plugin
  manifest declaration, checked independently on both sides of the call
  (Ruby's `FIRST_PARTY_PRIVILEGED_PLUGINS`, Go's `privileged.Registry`).
- **The only caller-supplied surface** is a short, explicitly allowed set of
  environment values (`TS_AUTHKEY`, `TS_HOSTNAME`, `TS_EXIT_NODE` — nothing
  else), validated with the same length/NUL-byte rules `checkEnv` already
  applies. Deliberately excluded: any "extra flags" passthrough. A generic
  `TS_EXTRA_ARGS`-shaped escape hatch would let a leaked token smuggle
  `--accept-routes`/`--advertise-routes`/etc. through what looks like
  configuration; keeping the env list to exactly the three settings the
  admin UI already exposes closes that off by construction.

What a leaked token *can* still do that it could not before: force a
recreate of the Tailscale container with a different `TS_AUTHKEY`, which
would re-enroll the node under an attacker-controlled tailnet and expose
whatever `tailscale serve` forwards (the internal Syrus web URL, a fixed,
non-caller-supplied value) to that tailnet instead of the operator's. That
is a real capability worth naming, not hand-waved away — but weigh it
against the status quo it replaces, not against zero: today, the same
threat model ("worker token/process compromise") already means direct shell
access to a container that already holds `NET_ADMIN`, `NET_RAW`, and the raw
TUN device, and that can already reach `http://web:80` directly over the
Compose network with no Tailscale involvement at all. Shape A is a strict
reduction in what worker compromise buys an attacker, not a new exposure:
the worker gives up direct capability entirely and gains only remote control
of one pre-approved, capability-scoped container it cannot reconfigure
outside three named settings. The residual risk (auth-key swap) is bounded
to that one container's network namespace — no host capability, no
Compose-network-wide lateral movement beyond what direct worker access
already grants, no privilege escalation path off the container (no
`privileged: true`, `no-new-privileges` still applies).

Recommended mitigation, not a blocker: log every `EnsurePrivileged` call
distinctly from ordinary `Ensure` calls in the manager, and surface recent
privileged-service env changes (not values — presence/timestamp) on the
Admin → Plugin Services detail panel, so an operator notices unexpected
auth-key churn instead of it being invisible.

## Where this surfaces in the Admin UI

**Admin → Plugin Services**, not a new page. Tailscale's container is a
managed service exactly like Git Mirror's: it appears in
`/admin/plugin_services`'s list with live state, image, endpoint, Stop /
Start / Restart, and log tail, and gets a Details panel once
`Tailscale::RuntimeService.service_details` is implemented (recent
connection state, tailnet hostname — the same information `StatusPayload`
already computes, just sourced from the container instead of the worker's
local socket). The one net-new piece of UI is a **"Privileged" badge** on
any service row where `Status.Privileged` is true, so an operator can always
see which of their running plugin services carry elevated capabilities
without opening each one's details — directly answering DOC-28's own
requirement that "a plugin service should be treated as privileged
infrastructure, not merely another provider class."

**Admin → Tailscale** (`/admin/tailscale`) stays as the tailnet-specific
page — it is about tailnet identity and connectivity, a different concern
from container lifecycle, the same way a repository's own settings page
stays separate from Plugin Runtime's view of Git Mirror. `StatusPayload`
changes what it reads, not what it renders: `daemon_running`/`connected`/
`hostname` come from an HTTP call to the Tailscale container's own status
endpoint (via `PluginRuntime::Services.endpoint_for("tailscale")`) instead
of a worker-local Unix socket, and `net_admin_capable` — which checks
`File.exist?("/dev/net/tun")` **on the worker** — is removed outright, since
after this migration the worker never has that device. Its replacement is
simply whether the service reports `running`.

**Image and versioning**: `plugins/tailscale/container/` joins the existing
`bin/publish-plugin-images` glob with no script changes needed — it already
walks every `plugins/<name>/container` with a Dockerfile. The image is
`ghcr.io/tkadauke/syrus-plugin-tailscale`, tagged identically to every other
plugin service (`:latest`, `:<SYRUS_VERSION>`), pinned by `bin/deploy` on
Kubernetes the same way Git Mirror's already is. No bespoke pipeline.

**Logs**: the existing `GET /v1/services/{name}/logs` is reused unchanged.
Log retrieval carries no elevated risk beyond what Git Mirror's logs
endpoint already allows, so it does not need a privileged counterpart.

## Kubernetes / external mode

Unchanged, and that is the point: `ExternalDriver` never touches Docker in
any mode, so an operator running Tailscale as a privileged Kubernetes
DaemonSet with its own `NET_ADMIN`/TUN grant, and setting
`SYRUS_PLUGIN_SERVICE_TAILSCALE_URL` to its in-cluster address, is already
exactly what "external mode" means today. Zero new code is needed on that
path. What is new is only documentation: `privileged` services should say
in `docs/syrus_docs/plugin_runtime.md` that the privileged lane is a
Compose-only mechanism (the runtime manager doesn't run under Kubernetes at
all), and that Kubernetes installs always run privileged services the
external way, deployed and secured by the operator's own manifests.

## Implementation plan (sized as follow-up jobs)

This job produces the decision and the contract; each numbered item below is
sized to be its own job.

1. **Plugin Runtime manager (Go)**: `internal/privileged` package
   (`Definition`, `Registry` with the single `tailscale` entry, its own
   request/validate functions mirroring `policy.checkEnv`'s rules),
   `manager.EnsurePrivileged`, the new `CapAdd`/`Devices` fields on
   `docker.HostConfig` (populated only from `EnsurePrivileged`), the
   `LabelPrivileged` label and `Status.Privileged` field, and the
   `PUT /v1/privileged/{name}` route. Test the same way `manager_test.go`
   and `policy_test.go` already do: fake Docker client, assert the
   generic `Ensure` path still cannot express capabilities/devices, and
   assert `EnsurePrivileged` rejects an unknown name or an env key outside
   `AllowedEnvKeys`.
2. **Plugin Runtime plugin (Ruby)**: `PluginRuntime::PrivilegedService`
   contract module (mirrors `PluginRuntime::Service`'s doc-comment style),
   `DesiredPrivilegedServices` with the `FIRST_PARTY_PRIVILEGED_PLUGINS`
   constant, `Client#ensure_privileged_service`, wiring into
   `ManagedDriver#reconcile`, and the `Privileged` flag threaded through
   `ServiceStatus` into the admin payload and the new badge in
   `AdminPluginServices.tsx`.
3. **Tailscale container image**: `plugins/tailscale/container/`, a small
   Go binary (matching Git Mirror's shape — cross-compiled, unprivileged
   user where possible, though `tailscaled` itself needs to run as root
   inside its own container to touch the TUN device) that runs `tailscaled`,
   applies `tailscale up`/`tailscale serve` on start and whenever its env
   changes, and exposes `/healthz` plus a `/status` endpoint that proxies
   `tailscaled`'s local API — replacing the Unix-socket reads
   `StatusPayload`/`HostAllowlist` do today. Give it a named volume for
   `/var/lib/tailscale` state; this also fixes a real, separate latent bug
   in the current code, where `STATE_PATH = "/tmp/tailscaled.state"` lives
   in the worker's ephemeral storage and re-registers the node as new on
   every worker restart.
4. **Tailscale plugin migration**: `Tailscale::RuntimeService`
   (`plugin_runtime:privileged_service` provider), rewiring
   `Tailscale::Callbacks`/`HostAllowlist`/`StatusPayload` to call the
   container over HTTP via `PluginRuntime::Services.endpoint_for("tailscale")`
   instead of `Process.spawn`/`UNIXSocket`, deleting `Tailscale::DaemonManager`,
   and removing `worker`'s `cap_add`/`devices` block (and its two
   "connectivity plugin" comments) from `docker-compose.yml`. Update
   `plugins/tailscale/README.md` and
   `plugins/tailscale/docs/syrus_docs/tailscale.md` to describe the new
   transport; `config_schema` (`auth_key`/`hostname`/`exit_node`) does not
   change. Add `plugin_runtime` as a hard dependency of `tailscale`
   (`depends_on: ["plugin_runtime"]`), matching Git Mirror's declaration.
5. **`plugin_runtime.md` doc update** (only once shipped): add the
   privileged lane to "What the runtime manager refuses" as the one
   documented exception, naming exactly what it allows (a single compiled
   first-party service, a fixed capability/device set, a short allowed env
   list) so the doc keeps describing shipped reality rather than this plan.
6. **Rollout**: ship items 1–3 and land item 4 in the same change that
   removes the old worker-hosted path — no dual-path window where both the
   in-worker daemon and the container-backed service could plausibly run
   at once. Verify in a real Compose stack (`bin/compose-up`) that the
   worker starts with no `cap_add`/`devices` at all and the tailnet node
   still comes up through the new container before removing the old code.

## Open questions carried forward

- If a second privileged service is ever proposed, does one `Definition`
  table remain the right shape, or does the allowed-env-list pattern stop
  generalizing once a service needs richer configuration than a handful of
  strings? Revisit shape B at that point if the answer is "no" — the
  isolation/operability tradeoff argued here is specific to how narrow
  Tailscale's actual configuration surface is.
- Should enabling a plugin that owns a `plugin_runtime:privileged_service`
  require an explicit operator confirmation step in Admin → Plugins (an "I
  understand this container gets elevated network capabilities" gate),
  rather than the same one-click enable every other plugin gets? Worth
  deciding before item 4 ships, not assumed here either way.
