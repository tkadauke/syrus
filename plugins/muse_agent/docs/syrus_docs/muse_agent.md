# Muse Agent Rollout

Muse Agent connects Syrus workflow and chat execution to Muse Code through the
`muse_agent` plugin. It is installed in the application but defaults to
disabled so operators can pilot Muse cautiously and turn it off immediately if
provider behavior changes upstream.

## Enablement

Enable Muse from **Admin -> Plugins -> Muse Agent** after the runtime image and
pilot users are ready. Disabling the plugin removes `muse` from workflow agent
provider and chat provider registry lookups, disables Muse credential probing,
and hides Muse as a new provider option. It does not delete encrypted
`User#muse_api_key` values that users already saved.

Existing plugin records keep their current enabled state across deploys; the
disabled default only affects fresh installs or instances that have not already
enabled the plugin.

## Prerequisites

The worker/backend image must have the `muse` launcher on `PATH`. Syrus
production images install it under `/opt/muse/bin`, prepend that directory to
`PATH`, and set `MUSE_NO_AUTO_UPDATE=1`.

That image-level variable is not by itself what pins the CLI at run time. Both
`MuseInvocation` and `MuseCredentialProbe` scrub the environment down to
`AgentInvocation::ENV_FORWARD`, which does not carry `MUSE_NO_AUTO_UPDATE`, so
the plugin re-adds it explicitly through `MuseInvocation::LAUNCHER_ENV`. Without
that, every invocation re-enables the launcher's update check: the launcher
tries to write its timestamp into the read-only `/opt/muse/bin` (surfacing as
`Permission denied`) and spends the better part of two minutes on a network
check before the agent turn starts. On a worker that cold start measured one
second with the flag forwarded and over two minutes without it, which is enough
to exhaust the 30-second credential-probe budget on its own.

Muse API credentials are a separate requirement. Each Syrus user who wants to
run Muse must save a Muse API key under **Credentials -> Muse**. The key is
encrypted on `User#muse_api_key`, redacted from process output through the
plugin secret extractor, and passed to Muse over stdin with `--api-key-stdin`.

Create the key at <https://ai.developer.meta.com/> under **API keys**. Muse keys
begin with `LLM|`. A subscription's key and any pay-as-you-go keys both appear
there; which one you save decides how the runs are billed, so check the project
a key belongs to before saving it.

A key's value is shown only once, at creation, and cannot be revealed or rotated
afterwards. An operator who signed in with a Muse subscription through `muse
login` and no longer has the key can recover it from the credential store the
CLI writes -- on macOS, Keychain Access, item `ai.meta.dev.credentials`. That
entry is a JSON document holding both `api_key` and an OAuth `access_token`, and
**Credentials -> Muse** accepts the document pasted whole: `User` normalizes it
down to `api_key` and discards the access token, which Syrus has no use for.
Anything that is neither a bare key nor a parseable document is stored verbatim
so the probe reports it rather than silently blanking the field.

Note that the account login `muse login` performs is not itself usable for
headless runs. It is device-code OAuth held in the OS credential store, and
Syrus scrubs `HOME` to a per-workflow or per-chat Muse home, so agent runs never
see it. The saved API key is the only credential that reaches them.

## Smoke Tests

Run the no-credential echo provider probe first to confirm the CLI exists and
can emit JSONL:

```sh
muse exec --json --provider echo "Reply with OK."
```

Then run a credentialed Meta provider probe from a worker-like shell:

```sh
printf '%s' "$MUSE_API_KEY" | muse exec --json --provider meta --api-key-stdin "Reply with OK."
```

In Syrus, use the Credentials page Test action for `muse_api_key` after the
plugin is enabled. The probe runs the same credentialed Meta provider shape
with the saved key on stdin.

## Supported Surfaces

Workflow jobs can use Muse wherever Syrus asks `AgentProviders.for("muse")` to
run an agentic step. Muse writes a per-workflow home, configures
`~/.config/muse/settings.json` with a stdio `syrus-mcp-sidecar`, and uses Muse's
MCP tool namespace such as `mcp__syrus_mcp_sidecar__submit_summary` when checking
required workflow tools. The generated settings file always carries the top-level
`schema_version: 1` Muse Code requires, and each `mcp_servers` entry is
normalized into Muse's documented stdio shape (`transport: "stdio"`,
`command`, `args`, `env`, `enabled: true`, `mode: "required"`) regardless of
what an existing (or legacy) settings file on disk looked like —
`MuseInvocation#write_muse_settings!` repairs a settings file that is missing
`schema_version` or isn't valid JSON rather than crashing, and preserves any
unrelated top-level settings already present.

Syrus Chat can use Muse as an enabled `chat_provider` when the user has a saved
Muse API key. Chat turns use a per-chat Muse home and stdio chat sidecar
configuration. Stale Muse chat session resumes retry once as a fresh session
using durable chat history.

Muse currently does not use the persistent MCP HTTP sidecar. The provider
downgrades workflow MCP transport decisions to per-run stdio, and chat Muse
turns read the sidecar command from the generated Muse settings file.

## Model And Effort Knobs

Muse invocations always use `muse exec --json --provider meta`. Syrus appends
optional CLI flags only when values are configured:

- `--model <value>` from the selected chat model or direct invocation model.
- `--reasoning-effort <value>` from chat effort settings.
- `--max-model-steps <value>` from Syrus' max-turns/max-steps limit.

Unset values are omitted instead of guessed.

## Transcript And Redaction Policy

Workflow transcript capture defaults to:

```sh
muse export --session <session-id> --redacted --out <file>
```

Raw workflow export is available only through an explicit `:raw_export` policy.
If `muse export` is unavailable or fails, Syrus falls back to the captured exec
JSONL stream and logs that fallback. Chat turns intentionally store exec JSONL
for resumable provider sessions.

Syrus redacts the saved Muse API key from startup output, terminal failure
details, credential probe output, and run logs through the plugin secret
extractor. Operators should still treat raw transcript exports as sensitive
because tool inputs, repository content, prompts, and provider diagnostics may
contain project data.

## Differences From Claude And Codex

Claude and Codex have mature provider-specific auth, usage, and MCP transport
paths. Muse is newer and intentionally gated through the plugin toggle.

Muse authenticates with an API key rather than a Claude subscription OAuth token
or Codex API key/ChatGPT login choice. A Muse subscription issues its own API
key alongside any pay-as-you-go keys, so the credential shape is the same either
way and only the key you save decides which pool the runs draw from. Syrus does
not yet have a structured Muse usage probe; usage, quota, billing, and auth
failures are classified reactively from Muse invocation errors, and there is no
in-app indication of which pool a saved key belongs to.

Muse's MCP integration is settings-file based. Syrus writes isolated Muse homes
instead of passing an MCP config flag, and persistent MCP HTTP transport is not
wired for Muse yet.

Muse emits JSONL envelopes with `payload_type`; Syrus normalizes those events
for transcript rendering, tool-call summaries, and required-tool checks.

## Known Limitations

Required workflow MCP tools fail fast after Muse reports a tool inventory that
does not include them, or after the process exits without satisfying them. If a
Muse CLI release changes its inventory event shape, disable the plugin while
updating the adapter.

Disposable chat evaluator sessions receive rehydrated transcript context in the
prompt because Muse does not expose a separate transcript import flag.

Provider availability pause can react to Muse auth, quota, and transient
failures after an invocation, but there is no proactive Muse usage reset window
or remaining-credit display.
