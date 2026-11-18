---
title: Plugins
description: How Syrus plugins extend UI, tools, prompts, graders, previews, and integrations.
---

# Plugins

## Prebuilt frontend bundles

An externally installed plugin may ship its UI as a prebuilt ESM bundle and
stylesheet. Syrus serves and loads those files for enabled plugins at startup,
so installing UI contributions requires a restart but no rebuild of the core
frontend. If one bundle fails, Syrus logs and skips it while the application
continues loading.

Every plugin UI contribution is isolated by an error boundary. A render error
or rejected lazy import shows a compact plugin-named reload action and is sent
through Syrus's browser error reporting without taking down the surrounding UI.
External manifests may also declare `frontend.i18n` JSON files under
`app/frontend/i18n/locales/{en,de,la}/`; Syrus loads the active language from
content-hashed URLs and falls back to English if that locale cannot be loaded.

Plugin bundles share the host's React, React DOM, TanStack Query, i18next, and
react-i18next runtimes through the documented `@syrus/plugin-sdk` build
contract. Their own CSS must be complete; core does not compile utility classes
from an external plugin's source.

Plugins are installed extension bundles. Installing a plugin makes its code
available after restart; enabling a plugin makes its surfaces visible and its
behavior active. In general, the plugin enable switch is the feature flag for
that plugin.

External plugins can declare a `requires_syrus` Ruby version requirement, such
as `>= 0.1.16`. Syrus withholds a plugin whose requirement is not met and shows
the required and running releases in plugin health. If the running release is
unknown, Syrus loads the plugin and records that the compatibility check was
skipped. Plugin authors should declare the oldest Syrus release they have
actually tested. Before publishing, run `bin/plugin-host-surface scan PATH`
(or add `--json` for tooling). Registered `Syrus::Host` APIs are supported;
legacy and literal dynamic core names produce warnings, while direct
unsupported core references make the command fail. The report derives the
minimum Syrus release required by the host APIs in use. Computed dynamic
constant names cannot be detected. The tested release may be
newer, but must not be older than that derived floor.

## Validate and test a plugin

Create a project with `syrus plugin new NAME`. The command writes `./NAME` by
default; use `--path DIR` to choose another empty directory. The generated
project includes a gemspec and manifest, a callback-provider example, English,
German, and Latin locales, host-contract specs, a README, and a GitHub Actions
workflow that runs `syrus plugin test`.

Add `--frontend` for an admin-page source example and prebuilt bundle,
`--model` for a namespaced model and migration, or `--cli` for a server-backed
CLI command. `requires_syrus` defaults to the connected instance release and
falls back to the CLI release; override it with `--syrus-version X.Y.Z`.
Names must be lower-case Ruby-compatible snake case and cannot collide with a
plugin known to the instance or bundled into the CLI. Existing non-empty
directories are never overwritten.

Run `syrus plugin validate [DIR]` to check the manifest, Ruby dependencies,
release compatibility, host API usage, prebuilt frontend hash, and English,
German, and Latin locale parity. Run `syrus plugin test [DIR]` for the same
validation followed by the plugin's own RSpec suite. Both commands default to
the current directory and run against the connected instance's release when it
is available, otherwise the CLI release. Use `--syrus-version X.Y.Z` to select
a release explicitly and `--json` for the stable summary object.

The CLI pulls the matching `ghcr.io/tkadauke/syrus-plugin-test` companion image
and mounts only the plugin directory; no instance credentials enter the
container. Syrus contributors can use `--checkout PATH` to execute the same
runner from a local Syrus checkout without Docker.

## Hand-install an external plugin

External plugins are trusted, in-process code. Review the source before
installing it: the plugin receives the same database, filesystem, network, and
credential access as Syrus. A dropped-in plugin directory may depend on Rails
but cannot bring additional Ruby gems; its browser dependencies must be bundled
into its prebuilt frontend output.

Set `SYRUS_PLUGIN_PATH` to a shared root whose immediate children are complete
plugin directories. Mount the same contents read-only in every container that
boots Rails, including web, workers, setup/migration, and preview processes.
Stage a complete plugin directory outside the live root, stop Syrus, atomically
place or replace the directory, run the normal deployment migrations, and
restart every Syrus container. Syrus discovers the plugin's `db/migrate`
directory automatically, and migrations run even while the plugin is disabled.

After restart, inspect **Admin → Plugins** before enabling the plugin. The page
shows dependency problems, compatibility, and retained load failures. An
incompatible or failed plugin contributes no routes or providers and does not
stop healthy plugins or core from loading.

Syrus also isolates ordinary failures from plugin providers at runtime. The
admin page shows recent failures and open circuits. After repeated failures in
a sliding window, a process-local circuit declines calls until its cool-down
expires; one successful trial closes it, while another failure reopens it.
Circuit histories can differ between web and worker processes because they are
kept in memory.

Plugin-owned routes use the same production-isolation policy. An unhandled
route exception returns a structured error that names the plugin, records the
latest error under **Admin → Plugins**, and does not prevent a healthy sibling
plugin from serving requests. The health view also shows each plugin's request
count and latest route-error time. Each process retains at most 100 distinct
recent failure signatures per plugin, bounding both runtime memory and the Admin
health payload. Development and test keep raising these exceptions through
Syrus's normal error handling so plugin defects stay visible.

The runtime breaker defaults to five failures within 60 seconds and a 30-second
cool-down. Set `SYRUS_PLUGIN_CIRCUIT_FAILURE_THRESHOLD`,
`SYRUS_PLUGIN_CIRCUIT_WINDOW_SECONDS`, and
`SYRUS_PLUGIN_CIRCUIT_COOLDOWN_SECONDS` on every Syrus process to tune those
values. Provider timeouts remain opt-in per operation. This in-process boundary
contains ordinary bugs, not malicious code, native-code hangs, memory growth,
monkey patches, or process termination.

To uninstall, disable the plugin and resolve any usage blockers, stop every
container, move its directory out of the shared root, and restart all
containers. Keep its data for rollback; destructive purge is a separate,
explicit operation.

Multi-process installations can also publish external plugin releases as a
signed desired set in the configured attachment storage. Archives are addressed
by SHA-256, and each manifest revision names the exact release, size, process
roles, and quarantine state. Pre-boot consumers verify the detached Ed25519
signature and every artifact digest before activating a set. Operators
distribute only the public verification key; Syrus keeps the signing key
encrypted with its other application credentials.

Set `SYRUS_PLUGIN_SYNC_ENABLED=1` on each Rails process and provide
`SYRUS_PLUGIN_MANIFEST_PUBLIC_KEY`. The pre-boot sync reads from the configured
S3-compatible attachment bucket using `S3_BUCKET`, `S3_ENDPOINT`, `S3_REGION`,
`S3_ACCESS_KEY_ID`, and `S3_SECRET_ACCESS_KEY`. Single-node installations can
instead set `SYRUS_PLUGIN_SYNC_STORAGE_PATH` to the local attachment-storage
root. Synced sets live under `$SYRUS_DATA_ROOT/plugin-sync`; activation changes
the `current` symlink atomically, and the previous set remains available as
`last-good`.

Sync failures do not block boot by default. An unreachable store, invalid
signature, malformed manifest, unsafe archive, or artifact size/digest mismatch
prints one error and retains the active set. Set `SYRUS_PLUGIN_SYNC_STRICT=1`
when a process should fail instead. `SYRUS_PLUGIN_SYNC_RETENTION` controls the
number of additional inactive sets retained beyond `current` and `last-good`
(default `2`). The entrypoint exports `SYRUS_PLUGIN_SET_DIGEST` and
`SYRUS_PLUGIN_SET_REVISION` to Rails and its sidecars. Fleet-quarantined or
revoked entries are omitted from the activated set. A hand-placed plugin root
still takes precedence over a same-named synced plugin and the collision is
reported by plugin health.

Plugin authors may limit loading with `roles %w[web worker preview sidecar]`;
the default is every role. After changing desired plugins, **Apply changes**
drains web, worker, and preview processes and lets the container restart policy
rerun pre-boot sync. The status identifies processes still pending or stuck.
Setup and web apply plugin migrations normally, while workers stop at boot if
any migration remains pending.

### Reading fleet convergence

**Admin → Plugins** compares the desired revision with every process heartbeat.
`Converged` means the process reports the role-specific desired digest. `Pending
restart` means an applied revision has not started there yet; restart that
process. `Behind` means it is running an older set without a current restart
request; verify sync configuration and restart it. `Ahead` means the process is
running a revision newer than this control plane; verify that it points at the
correct database and manifest store. `Unreachable` means its heartbeat is stale;
restore or replace the process before trusting its plugin state.

Each row lists the running version and local load state for every desired plugin,
including role skips, load failures, missing plugins, and fleet quarantine. Rows
that remain divergent longer than
`SYRUS_PLUGIN_DIVERGENCE_THRESHOLD_SECONDS` (five minutes by default) are
highlighted and produce the standard system alarm with a link back to Plugins.

### Recovering from a broken plugin

Set `SYRUS_SAFE_MODE=third_party` to withhold external plugins, `recent` to
withhold external plugins changed since the last good boot, or `all` to boot
without plugins. Syrus core requires no plugin to boot. Safe-mode and
quarantine reasons appear in Admin → Plugins and in the global admin warning.

Syrus records boot attempts outside the database. After three incomplete boots
within ten minutes, it quarantines changed external plugins on the next start;
a process that remains up for 60 seconds promotes its plugin set to last-good.
Fleet quarantine from desired state takes effect on restart as well.

If the UI works, correct the plugin and choose **Re-enable after restart** one
plugin at a time. If Rails does not boot, use `bin/plugin-recovery list`,
`bin/plugin-recovery quarantine NAME`, and `bin/plugin-recovery clear NAME`.
Restart after changes. Clear fleet quarantine in desired state, and remove
`SYRUS_SAFE_MODE` only after the recovered process remains healthy.

## What Plugins Can Add

Plugins can contribute:

- sidebar and admin navigation entries,
- repository tabs,
- React components bundled into the app,
- MCP tools for chat and workflow agents,
- server-backed CLI commands discovered by the `syrus` CLI,
- prompt context injectors,
- typed artifact renderers,
- preview providers,
- prepare detectors,
- grader augmentors,
- CI log parsers,
- dependency-audit commands,
- affected-test analyzers,
- execution backends for constrained process runs,
- source integrations such as GitHub or Linear,
- speech-to-text backends for chat dictation,
- batched badges and plugin-defined filters for chat search results.

The bundled Rails plugin's migration artifacts are execution-backed: it loads the
workflow base schema into a disposable database, applies newly added migrations in
order, and shows normalized before/after catalogs. Data-only migrations and artifact
generation failures are labeled explicitly; environments without disposable-database
support receive a clearly marked cumulative schema-dump comparison. The sandbox
redirects every named application database to a distinct sandbox and supports both Ruby and SQL schema dumps.

Plugins can also declare stable credential type names for a
credential-management plugin to discover. These declarations are intentionally
metadata-only: a name such as `k8s_cluster.kubeconfig`, plus optional safe label
and description text. Credential storage, encryption, payload parsing,
authorization, broker materialization, redaction, and credential-use callbacks
remain outside this hook.

Enabled plugins may publish non-interactive commands in the server command
catalog. The CLI discovers nested paths such as `syrus docs list`, validates
their declared positional arguments and flags, and asks Syrus to execute the
plugin's Ruby handler as the authenticated API user. Commands return table,
text, or JSON output; disabled or unhealthy plugins contribute no commands.

The core app should keep behavior that is required for Syrus to function.
Plugins should be things that can reasonably be disabled, replaced, or
distributed separately.

The optional Container Execution backend can use a repository's standard
`.devcontainer/devcontainer.json` or `.devcontainer.json` as its seed image.
With devcontainer support enabled, it pulls an `image` declaration or builds a
`build` declaration for container-backed graders; `.syrus.yml` prepare and
grader configuration continues to run on top of that image. Repositories
without a devcontainer and local execution keep their existing behavior.
Concurrent builds for the same revision are deduplicated within each Docker
image store. Workers connected to one shared remote daemon should use the same
`SYRUS_CONTAINER_EXECUTION_DOCKER_NAMESPACE`; separate local daemons are scoped
independently by default.

## Bundled Plugin Directory

The public plugin directory at [/plugins](/plugins) is generated from the
bundled plugin manifests, so it is the most complete browsable list. This
snapshot calls out the launch-relevant groups:

| Group | Bundled plugins |
| --- | --- |
| Agent providers | Claude Agent, Codex Agent, Antigravity Agent, Muse Agent |
| Work inputs and planning | Walkthrough Videos, Scheduled Tasks, GitHub Source, Linear Source, Design Docs, Operator Briefing |
| Repository intelligence | Agent Insights, Agent Memory, Git History, Search, Test Insights, Throughput, Metrics Dashboard, Spending Insights, Attention Report |
| Language and platform support | Browser (Playwright), Django, Go, iOS, Java, JavaScript, Kotlin, Python, Rails, Ruby |
| Runtime and infrastructure | Git Mirror, GitHub Host, Kubernetes Cluster Viewer, Plugin Runtime, Tailscale, Terminal, Runtime Terminal, Worker Timeline, Build Cache |

Worker Timeline uses the shared composable filter bar and Smart Folders. Saved
timeline expressions can combine supported fields with nested AND, OR, and NOT
groups across workflow spans, pending workflows, and idle worker lanes.

The Kubernetes Cluster Viewer reports kubeconfig credential expiry in its
admin cluster list. Operators rotate pasted tokens or client certificates by
editing the existing connection and pasting a replacement kubeconfig, which
keeps cluster identity and access settings intact. OIDC auth-provider
kubeconfigs with refresh credentials renew automatically shortly before
expiry; failures appear as a degraded credential state without exposing
secret material.
| Collaboration and UI | Agent Activity, Review Notes, Credential Store, Discord, Mockups, Team Directory, Theming Tools, Whiteboard |
| Data and admin tools | Admin MySQL, MySQL DB Browser, Alertmanager Investigations, Syrus Dev, Whisper speech-to-text |

The Design Docs plugin gives chat agents a grouped archive tool for
multi-document cleanup. A single request can preview up to 100 `DOC-N`
targets, report documents that are already archived, and present one operator
confirmation with per-document results; the existing single-document archive
tool remains available for one-off requests.

Design Doc suggestions reserve their selected range while they are pending.
Another suggestion may start or end at the same boundary, but cannot overlap
that active range until the existing suggestion is accepted or rejected. When
reviewing an unrelated suggestion, Syrus repairs damaged or colliding pending
anchors by marking those suggestions stale instead of blocking the review.

Whiteboard's high-level arrow tool creates connectors anchored to the visible
edges of rectangles, stickies, ellipses, and diamonds. Optional arrow labels
render as bound text and move with the connector, while raw scene updates
remain available for advanced Excalidraw geometry.

Metrics Dashboard records the same bounded metrics exposed to Prometheus. Its
feature-usage and admission-decision counters combine increments from every web
and worker process into monotonic shared totals. If that cross-process snapshot
is unavailable or stale, those charts omit new readings and show an operator
warning instead of presenting the recorder process's local zero as complete.
Raw one-minute samples are retained for seven days—the longest window the
dashboard plots—and a daily recurring task prunes older rows.

MySQL DB Browser connections inherit access from their Credential Store scope:
user, repository, team, or instance. New connections default to the creating
user, while existing instance-scoped connections remain shared until an admin
narrows them. Legacy embedded passwords are admin-only until migrated by
re-entering the password in the connection editor.

Admin MySQL and Browser publish scoped agent-permission boundaries. Admin
database observation is distinct from exact-invocation query interruption.
Browser observation, loopback navigation, interaction, JavaScript evaluation,
upload, and session close are separate capabilities; evaluation and upload
ask per invocation. Loopback-only navigation, exact upload paths, admin and
repository checks, and Coding Mode input leases remain hard safety ceilings.

Credential Store SSH tools publish unified permission metadata evaluated from
arguments before credential resolution. Interactive chat requests can be
allowed once, for that chat, or permanently until revoked. Every grant is
scoped to a destination, which may be one exact address or a deliberately
broader prefix of it — every user on a host, every host reachable with one
credential — while the command is bound by a stable fingerprint. Read-only diagnostics and risky commands are
classified separately and never share authority. Existing credential
scope, destination and host-key checks, redaction, auditing, and short
secret-material leases remain non-overridable ceilings. Runtime CLI wrappers
continue to require authenticated Syrus invocation context and explicit
authorization for operator-host or risky execution.

Provider copy on the homepage and FAQ should use the adapter display names
from `plugins/*/lib/*.rb` and `AgentProviders::*#display_name`, not hand-rolled
model names. As of this release, the provider adapters are Claude Code, Codex,
Antigravity, and Muse Code.

## Installed vs Enabled

Installed means the plugin's code, migrations, translations, and frontend
assets are present. Enabled means Syrus uses the plugin at runtime. This lets
operators install a plugin during deployment but turn it on only for the
repositories or users that need it.

Some plugins may be non-disableable because they provide core surfaces for a
given distribution. Most should be disableable.

Some bundled plugins are marked experimental. They remain visible in Admin ->
Plugins and are still part of the installed Syrus build, but a self-hosted
instance must enable beta mode before enabling them. When an experimental
plugin is disabled and beta mode is off, the Admin Plugins page shows an
Experimental badge and an Enable beta mode action. The same server-side guard
applies to API calls and dependency cascades, so a stable plugin cannot be
enabled if that action would also turn on an experimental dependency. Beta mode
does not enable any plugin by itself; it only allows admins to explicitly turn
on beta or experimental capabilities.

A disabled plugin is not loaded. Its code stays resolvable, so enabling it
takes effect immediately without a restart, but Syrus does not pay to load
features nobody can reach. Migrations are the exception and always run at
deploy time regardless of enabled state, so enabling a plugin finds its tables
ready.

Disabling a plugin stops it doing work; it does not throw away the data it
already wrote. That data is still cleaned up when its owner is -- deleting a
repository still takes its plugin rows with it, whether the plugin is on or
off.

## Suggested Plugins

Syrus can tell you a plugin is worth turning on before you go looking for it.
A plugin can declare what its own signal looks like, and Admin -> Plugins shows
the ones this instance appears to want, with the evidence behind each: how many
of your repositories are Python, which repositories have a resolvable Django
settings module, whether you are running more than one worker host, or whether
you are on MySQL. Plugins you have already enabled are never suggested, and a
suggestion with no evidence behind it is not shown at all.

The repository side of this is observed while Syrus already has a clone in
hand, during a normal run, so a repository Syrus has never worked on produces
no suggestion.

## Plugin Data

Plugins can own database tables. When they do, table names and model
namespaces should make ownership obvious, such as `linear_tickets` for
`Linear::Ticket`. Plugin migrations should avoid surprising global changes and
should follow the same no-foreign-key policy as the rest of Syrus.

## MCP Tools

Workflow and chat agents see tools through toolsets. A plugin should expose a
toolset as the registration point, but individual tools should stay small and
separately testable. Good tools have narrow inputs, clear side effects, and
structured results.

Every new agent-callable tool definition must include an explicit capability
descriptor. Versioned capability and operation identifiers, aliases retained
after renames, side effects, eligible-role defaults, autonomy limits, and
resource scope form its stable authorization contract. CI rejects missing or
conflicting definitions and identifies the provider, surface, and tool that
needs correction. A plugin may keep its older bundled definitions on a frozen,
manifest-owned compatibility baseline while they are migrated; core does not
carry plugin provider names or inventories, and that baseline cannot grow.
Typed resource scopes are provider-defined through a shared schema contract.
Providers apply the caller's normal resource visibility during lookup; hidden
and unknown identifiers receive the same result. Syrus canonicalizes and
validates normalized scopes and treats any lookup or normalization failure as
a closed authorization outcome.

Plugin authors can expose reusable permission metadata through a
`permission_provider`. The provider registers typed resource scopes and
complete capability operations, including effects, classifiers, redactors,
stable fingerprints, eligible-role recommendations, requestability defaults,
autonomy ceilings, and supported authority durations. Tool definitions reuse
the registered immutable descriptor instead of copying policy. Conflicting
operation or resource-type registrations fail closed, and a disabled plugin's
permission metadata is absent from the active catalog. Registration describes
what may be requested; it does not grant authority when a plugin is installed
or enabled.

Permission providers declare deterministic scope migrations when a new
operation version changes the normalized resource shape. Upgrade validation
rejects silent key removal, reuse of a retired identifier, and broader effects,
roles, defaults, autonomy, duration, or risk under an existing identity. A
renamed key must remain an alias; an intentionally removed key stays reserved
through an explicit retirement declaration.

MySQL DB Browser uses this contract to scope connection, database, table,
query, schema, and administrative access independently. Its SQL classifier
distinguishes reads, data writes, schema changes, and administrative effects;
uncertain statements receive the maximum critical-risk classification. Query
authority is limited to one invocation, fingerprints normalize harmless SQL
whitespace, and authorization displays redact the SQL text. Its read-only and
query-operator presets remain inert until an operator confirms them.

Kubernetes Cluster Viewer separates ordinary observation, secret metadata,
workload operations, node administration, and raw kubectl authority. Rules can
target a cluster, namespace, resource kind, or individual object. Observation
may be bounded to a Job and secret metadata to a chat session; mutations and
raw commands require exact-invocation authority. Existing per-cluster agentic
and write toggles remain ceilings and never grant these capabilities by
themselves.

Permission-provider authors can run `Permissions::ProviderTestKit` in their
RSpec suite. A small adapter supplies real provider probes for normalization,
redaction, hidden and unknown resources, uncertain classification, provider or
resource ceilings, descriptor upgrades, and plugin installation. The shared
suite reports the capability operation or resource scope that violates the
contract and verifies that installing or enabling the plugin creates no rules
or leases. Probes must exercise the plugin's real lookup and lifecycle paths,
not return a hand-built answer.

Providers can also register named permission presets made from complete rule
templates. A preset may render several role-, operation-, resource-, and
constraint-specific drafts. Syrus shows every rendered rule for operator
confirmation and creates the rules only after that confirmation. Role defaults
and presets are recommendations only: installing, enabling, configuring, or
migrating a plugin never applies them automatically.

Tool usage is logged so operators can see which tools are active, failing, or
worth consolidating.

## UI Contributions

Admin and repository pages are discovered from plugin declarations. Disabling a
plugin hides those pages, but the compiled JavaScript can remain part of the
app bundle. This keeps runtime enable/disable simple while still allowing
plugin pages to use normal React components.

## Dependencies

Plugins may depend on other plugins. If a dependency is disabled, Syrus should
warn or cascade-disable dependent plugins rather than exposing a broken UI
surface.

## Authoring Guidelines

Plugins that create Jobs with output intended for only some members of a
shared repository can register a `job_visibility_restriction`. The provider
names one Job `origin` and returns the origin IDs visible to the current user.
Syrus combines that restriction with normal repository access everywhere Jobs
are listed, searched, counted, or opened. Unrestricted origins behave exactly
as before, while instance admins retain their existing global access.

User-facing plugin code must use `Job.visible_to(user)` too, including plugin
pages, APIs, search sources, and MCP tools. Direct `Job.where(origin: ...)`
queries are reserved for the owning plugin's background lifecycle work. Full
provider signatures and an example are in the in-app Plugins documentation.

Keep plugin boundaries crisp:

- put plugin-specific tests with the plugin,
- namespace plugin models,
- prefix plugin-owned tables,
- use extension points instead of monkey-patching core behavior,
- make runtime disablement leave the rest of Syrus usable,
- keep the core test suite free of plugin specifics, so removing a plugin
  entirely leaves a passing suite rather than a red one.

Review features can contribute a generic review gate instead of changing core
workflow builders. A gate chooses the stable post-agent slot, declares
before/after ordering, enablement and loop budget, its repair relationship,
step/prompt/tool providers, verdict evidence, failure policy, and optional
panel support. Syrus validates the graph, preserves contribution metadata with
the Workflow, and stops scheduling later plugin-owned review iterations if the
plugin is disabled.

Syrus checks the last two by actually removing a plugin: `bin/plugin-boundary-audit
<plugin>` copies the checkout, deletes that plugin plus everything that depends
on it, and runs a command of your choosing — a boot check by default, or the
full test suite — against what is left.

Data removal is a separate, explicit operation after uninstall. Operators can
preview it with `bin/rails 'plugin:data[name]'` and confirm it with
`bin/rails 'plugin:purge[name]'`. Purge removes declared plugin tables,
plugin-owned rows and fields stored on shared tables, and contributed external
resources; disabling or uninstalling alone retains all of them.

Bundled plugins can also declare `config/plugin_ownership.yml`, covering their
configuration keys, workflow vocabulary, routes, data, tools, frontend
contributions, documentation, and domain terms. A checked-in compatibility
quarantine records existing core vocabulary as per-file baseline counts.
Boundary checks report new files, increases, and decreases as nonblocking
shadow-mode trends; developers do not update counts merely to make CI pass.
String counts are inventory rather than proof of architectural ownership, so
the subtraction command reports them separately from physical removability.
Enforcement is disabled by default and requires a later explicit operator
decision.

## Execution Backend Contract

Execution backends use the stable, versioned `Execution::Backend` contract.
Version 1.0 requires implementations to preserve read/write mount modes,
enforce the requested network profile, translate memory, CPU, and I/O limits,
make the persistent MCP daemon reachable through the advertised socket, and
reject malformed requests consistently. When a provider declines a request,
Syrus tries the next provider and ultimately falls back to local execution.

Syrus ships `Execution::BackendTestKit`, a transport-neutral RSpec conformance
suite. An in-tree or closed-source backend supplies a small adapter that runs
the real backend and reports a normalized observation of its transport. This
lets the same assertions cover local processes, containers, and private
execution systems without exposing backend internals. The operator guide
contains the adapter API and invocation example.

## Background jobs

Subclass `PluginJob` and declare `plugin :your_plugin` for plugin-owned
background work. Jobs use `plugin_your_plugin` by default, including jobs from
external plugins, and share a default concurrency cap of two. Pass
`concurrency: 5` to raise that cap, or use `queue_as` when a job genuinely
requires a specialized worker queue. The cap uses a renewable 15-minute lease,
so long-running jobs remain limited while abandoned slots recover. Plugins with
an unusual recovery window can pass `concurrency_duration: 30.minutes`.

Ordinary failures retry five times with polynomial backoff. After the final
attempt, Syrus discards the job and records the error in plugin health. Queue
depth, failed executions, and discarded-job counts are visible on the admin
Queue and Plugins pages.
