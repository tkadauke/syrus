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
actually tested.

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

To uninstall, disable the plugin and resolve any usage blockers, stop every
container, move its directory out of the shared root, and restart all
containers. Keep its data for rollback; destructive purge is a separate,
explicit operation.

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
Resource schemas may additionally return user-scoped authoring choices so the
Permissions Hub can offer visible resources by safe label instead of asking
for database identifiers. Those choices are presentation only; lookup and
validation still enforce visibility when authority is saved or used.

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

### Connected account providers

Service plugins can contribute an account connection through the hosted
`connected_accounts:provider` extension point. The provider declaration owns
its stable key and display name, callback route, read-only support, capability
list, and scope catalog. Each scope declares its provider key, human label,
risk (`low`, `medium`, `high`, or `critical`), and the Syrus capabilities it
enables.

```ruby
provides "connected_accounts:provider" => [
  {
    provider: "ExampleService::AccountProvider",
    key: "example",
    display_name: "Example Service",
    capabilities: %w[authorization exchange_code refresh revoke identity validate events],
    callback_route: "/connected_accounts/callback/example",
    supports_read_only: true,
    scopes: [
      {
        key: "records.read",
        label: "Read records",
        risk: "low",
        syrus_capabilities: [ "records.read@v1" ]
      }
    ]
  }
]
```

Every provider capability is a class method taking one context object. The
required methods and their result contracts are:

| Capability | Context fields | Result |
| --- | --- | --- |
| `authorization` | `redirect_uri`, opaque `state`, `requested_scopes`, `read_only` | `authorize_url` |
| `exchange_code` | callback `code`, original `redirect_uri` | Token hash with `access_token`, plus `refresh_token` and `expires_in` when supplied |
| `refresh` | current `tokens` hash | Replacement token hash with `access_token` |
| `revoke` | current `tokens` hash | Boolean `revoked` |
| `identity` | `access_token` | Human-readable external identity `label` |
| `validate` | `access_token` | Boolean `healthy` and a safe, non-secret `message` |
| `events` (optional, provisional) | request `headers`, raw request `body` | Verified `event_id`, `event_type`, and normalized `data` |

`authorization`, `exchange_code`, `refresh`, `revoke`, `identity`, and
`validate` are required. API-key and password providers use the same contract
with a trivial `authorization` implementation. Providers that declare
`events` must verify authenticity and fail closed before normalizing a push.
Token-bearing `exchange_code` and `refresh` results are returned only to the
Connected Accounts broker. Providers must not log token material or include it
in exceptions, user-visible output, or other external results.

Syrus rejects malformed declarations and providers with missing or invalid
method signatures at load time, with the reason visible in plugin health.
Provider authors can require `connected_accounts/provider_test_kit` and run
the shared `"a connected accounts provider"` RSpec examples. The bundled fake
provider is the reference implementation used by development and tests.

Service plugins register concept-level capabilities such as `mail.read@v1`,
not provider endpoint names, and keep acting identity explicit in the
`connected_account` resource scope. Split authority at least into read/search,
draft or private creation, actions that affect other people, delete, and
administration. Send/share/invite and similar outward operations default to
asking for exact-invocation authority. Service-specific mailboxes, calendars,
drives, channels, or comparable selectors belong in the scope's typed
`sub_resources` object rather than in the capability name.

Data removal is a separate, explicit operation after uninstall. Operators can
preview it with `bin/rails 'plugin:data[name]'` and confirm it with
`bin/rails 'plugin:purge[name]'`. Purge removes declared plugin tables,
plugin-owned rows and fields stored on shared tables, and contributed external
resources; disabling or uninstalling alone retains all of them.
Credential Store contributes cleanup for credentials in the purged plugin's
type namespace and their access-audit rows, even after that plugin's code has
been removed.

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
