# Codex Agent

The `codex_agent` plugin (`plugins/codex_agent/`) connects Syrus workflow
Runs and chat turns to the Codex CLI. It is default-OFF (fresh installs must
opt in through onboarding), customer-facing, and provides both an
`agent_provider` (`AgentProviders::Codex`) and a `chat_provider`
(`ChatProviders::Codex`), category `agent_provider`, `disableable: true`. It
runs independently of `claude_agent` — either or both can be enabled, and a
Job/chat picks a provider per invocation.

## Invocation (`CodexInvocation`)

```
codex exec [resume <id>] --dangerously-bypass-approvals-and-sandbox --json -
```

(or `codex exec --cd <workspace> ... -` for a fresh session). The trailing
`-` is Codex's stdin sentinel; the prompt is delivered on stdin
(`stdin_data:`), never as a positional argument, for the same
`Errno::E2BIG`/`MAX_ARG_STRLEN` reason `ClaudeInvocation` avoids argv.

Codex configuration is written to `<codex_home>/config.toml` rather than
passed as a CLI mcp-config flag:

```toml
cli_auth_credentials_store = "file"
approval_policy = "never"
model = "gpt-5.5"
model_reasoning_effort = "<level>"          # only when set and not "none"

[mcp_servers.syrus-mcp-sidecar]
command = "..."
args = [...]
required = true
startup_timeout_sec = 60
tool_timeout_sec = 60

[mcp_servers.syrus-mcp-sidecar.env]
KEY = "value"
```

`write_config` skips the actual file write when the generated content is
byte-identical to what's already on disk (`:unchanged`), avoiding
unnecessary churn on every invocation. `DEFAULT_MODEL` is `gpt-5.5`,
overridable instance-wide via `SYRUS_CODEX_MODEL`.

## Event stream

Codex emits JSONL with a `type` field. `CodexInvocation#process_event`
handles the outcome-determining events:

- `thread.started` — captures `thread_id` as the session id.
- `turn.completed` — success outcome; logs input/output/reasoning token
  usage.
- `turn.failed` / `error` — failure. The message is scoped with
  `codex_error_detail` (prefixed `"model <model>: ..."`) before usage-limit
  detection so a rate-limit match is attributed to the right model; matches
  against `ProviderUsageLimit.detect?` and `ProviderAuthFailure.detect?` are
  classified into `ProviderUsageLimit::OUTCOME` /
  `ProviderAuthFailure::OUTCOME` respectively before falling back to a
  generic `turn_failed`/`error` outcome.
- `item.started` / `item.completed` — the granular per-item stream
  (`process_item_event`): `agent_message` (assistant text, tagged
  `assistant_text_seen` for startup-timing instrumentation),
  `mcp_tool_call` (logged as `tool_call` while running, `tool_result` once
  `result`/`error` is present — tool names are `<server>.<tool>` joined from
  `item["server"]`/`item["tool"]`), `command_execution` (logged as a `bash`
  tool call/result), and `file_change` (system-only log line).

A line that fails to parse as JSON, or parses to something other than a
Hash, is treated as **startup output** rather than silently dropped:
`sanitize_startup_output` redacts anything after a `body:` marker (replacing
it with `[model metadata body omitted, N bytes]`, since that's often a large
verbatim API error payload) and byte-clamps to `STARTUP_ERROR_MAX_BYTES`
(4 KiB). If the process ultimately fails with no other outcome recorded, the
accumulated startup output becomes the failure's `final_text` — this is how
an operator sees *why* `codex exec` never got to a JSON event at all (a bad
model name, an auth rejection at process start, etc).

## Resume and transcript storage

Codex's own session files live under `<codex_home>/sessions/YYYY/MM/DD/
rollout-<timestamp>-<session_id>.jsonl` — the **canonical** filename shape.
`restore_resume_transcript` writes a stored `resume_transcript_jsonl` to that
canonical path before invoking a resume (Codex validates rollout files partly
by filename), falling back to a **noncanonical** glob match
(`*<session_id>.jsonl`, excluding files that already match the canonical
pattern) when no `jsonl` was passed in — e.g. a transcript captured under an
older on-disk shape. If no canonical path can be derived at all (an
unexpected session id format) or there is no rollout JSONL to restore, the
invocation falls back to a **fresh** session
(`effective_resume_session_id = nil`) rather than passing a `resume <id>`
Codex can't actually resume — logged as `[codex resume] ... starting a fresh
Codex session`. Any non-success outcome on a resume attempt is logged
(`log_codex_resume_failure`) with the observed reason.

`rollout_path_for` (used both to check for an existing rollout file and to
read the transcript back after the run) globs
`<codex_home>/sessions/**/rollout-*-<session_id>.jsonl` and takes the
most-recently-modified match.

## Agent provider (`AgentProviders::Codex`)

`provider_key` is `"codex"`. `configured_for_user?` checks either
`codex_api_key` (API-key mode) or `codex_auth_json` (ChatGPT-login mode),
selected by `user.codex_auth_mode`. `mcp_tool_name` builds
`<server_name>.<tool_name>` — Codex's own dot-joined naming, different from
Claude's `mcp__server__tool`.

`available_models` lists GPT-5.5 / GPT-5.2 Codex / GPT-5.1 Codex Mini as
rough categorical metadata (context window / cost tier), matching what
`model =` in `config.toml` accepts.

**MCP transport is stdio-only.** `effective_mcp_transport_decision` always
downgrades a `persistent`-transport decision to `stdio` with reason
`"provider_unsupported: codex has no persistent MCP HTTP transport wiring
yet"` — Codex's `config.toml` MCP config only models stdio servers, there is
no verified remote/HTTP transport for the CLI. The shared
`WorkflowMcpTransportSelector` still runs so its decision lands in the same
diagnostics stream as Claude's, it just never takes effect for Codex.

**Usage evidence.** `usage_snapshot`/`usage_status`/`usage_observed_at` read
straight off `User#codex_usage_snapshot`/`codex_usage_status`/
`codex_usage_observed_at` (persisted columns, unlike Claude which only lives
in `ProviderAvailabilityEvidence`). `evidence_reset_at` scans every window in
the snapshot (`primary`, `secondary`, `spend_control.individual_limit`, and
every entry in `additional_rate_limits`) for the earliest `reset_at` and adds
`ProviderQuotaReset::RETRY_BUFFER`. `false_positive_evidence?` and
`suppress_usage_limit_run?`/`ignore_model_for_positive_evidence?` exist
because Codex usage-limit messages have historically produced false
positives for certain models — see `ProviderUsageLimit.suspicious_model?`
and `ProviderAvailabilityEvidence.false_positive_codex_usage_limit?`.

## Auth modes (`CodexAuth`)

Two modes, selected by `User#codex_auth_mode`:

- **`api_key`** — `prepare_api_key` just returns the stored
  `codex_api_key`; no file writes.
- **`chatgpt_login`** — `prepare_chatgpt_login` validates
  `codex_auth_json` is a JSON object with a `tokens` hash carrying
  `id_token`/`access_token`/`refresh_token` (raising `CodexAuth::Error`
  otherwise), writes it to `<codex_home>/auth.json` with `0600` permissions,
  and returns no API key (Codex reads the file itself).

Because Codex can silently refresh `auth.json`'s tokens during a run,
`persist_updated_auth_json` reads the file back afterward and — if it
changed — writes it back to `User#codex_auth_json` **under a refresh lock**
(`with_refresh_lock`) so two concurrent Codex runs for the same user don't
race each other's token refresh. The lock is a real `GET_LOCK`/`RELEASE_LOCK`
pair on MySQL (`syrus:codex_auth:user:<id>`, 30-minute default timeout) or an
in-process `Mutex` keyed by user id otherwise (SQLite dev/test, which has no
equivalent cross-connection advisory lock). `stale_prepared_auth?` guards
against clobbering a *newer* refresh that happened while this invocation was
still running — if the DB's `codex_auth_json` no longer matches what was
prepared at the start, the update is skipped and logged rather than
overwriting fresher tokens. `api_key` mode skips the lock/reload entirely
(`with_refresh_lock` is a no-op unless `codex_auth_mode == "chatgpt_login"`).

## Credential probing and usage (`CodexCredentialProbe`, `CodexUsageProbe`)

`CodexCredentialProbe` runs `codex exec --cd <tmpdir>
--dangerously-bypass-approvals-and-sandbox --json "Reply with OK."` in a
scratch `CODEX_HOME`, under the same refresh lock `CodexAuth` uses. Two
credential specs exist — `codex_api_key` and `codex_auth_json` — each
checking the matching `codex_auth_mode` and returning a `wrong_mode_message`
if the user has the other mode selected. A successful probe in
`chatgpt_login` mode also force-refreshes usage (`CodexUsageProbe.refresh_for
(force: true)`) and attaches the snapshot to the probe's `details`.
`SECRET_EXTRACTOR` redacts both `codex_api_key` and every value under
`codex_auth_json`'s `tokens` hash.

`CodexUsageProbe` (ChatGPT-login mode only) calls
`https://chatgpt.com/backend-api/wham/usage` with the stored access token,
plus `ChatGPT-Account-ID` and (when applicable) `X-OpenAI-Fedramp` headers
derived from the id token's JWT claims (`jwt_claim`, a raw base64url decode —
no signature verification, since Syrus is only reading claims Codex itself
already trusts). Snapshot shape carries `primary`/`secondary` rate-limit
windows (each normalized with a human `label` such as `5h`/`daily`/`weekly`/
`monthly`/`annual`, derived from `limit_window_seconds` via
`duration_label_for`'s ±10% tolerance match), `credits`, `spend_control`, and
`additional_rate_limits`. Classification: `exhausted` when
`rate_limit_reached_type` is present, spend control reports `reached: true`,
or remaining percent is ≤0%; `warning` at ≤20% remaining
(`WARNING_REMAINING_PERCENT`); else `ok`. Staleness window is 10 minutes,
tracked on `User#codex_usage_observed_at` rather than a separate evidence
table lookup.

## Session rehydration and transcript rendering

`ChatSessionRehydrator::Codex` reconstructs Codex's
`thread.started`/`item.started`/`item.completed`/`turn.completed` JSONL shape
from `ChatMessage` rows for context-compaction and cross-session scenarios.
Notable differences from the Claude rehydrator: thinking blocks are dropped
entirely (Codex has no persistent reasoning state to restore); `bash`
tool-use rows map to `command_execution` items instead of generic MCP calls;
other tool names are split back into `server`/`tool` on the `.` separator;
and **user prompt rows are omitted** — `codex exec resume` takes the new
prompt directly rather than replaying prior turns from the JSONL, unlike
Claude's `--resume` which does replay.

`CodexAgent::TranscriptEvents` normalizes Codex's several observed on-disk
event shapes (`session_meta`, the older `event_msg`-family, the newer
`response_item`-family, plain `thread.started`/`turn.completed`, and
top-level `item.*`) into the same `ClaudeTranscript::Event` shape the UI
already renders Claude transcripts with, so the transcript viewer doesn't
need a Codex-specific rendering path.

## What's not here

There is no structured "which pool does this key draw from" indicator (API
key vs. ChatGPT subscription billing), matching the same gap noted in the
`muse_agent` and `claude_agent` docs. Startup timing instrumentation
(`CodexInvocation::StartupTiming`) logs stage timings but is not currently
surfaced anywhere in the operator UI beyond the Rails log.
