# Runtime Terminal

The `runtime_terminal` plugin (`plugins/runtime_terminal/`) adapts Syrus's
existing `terminal` plugin into a DOC-17 Runtime Session provider for Coding
Mode: a real worker-side shell an agent (or the operator, via the Runtime
panel) can drive as one of several interchangeable runtime targets
(alongside e.g. the `browser` plugin's headless-Chromium provider). It is
installed but **disabled by default** (`default_enabled: false`,
`disableable: true`), category `agent_capability`, and
`depends_on: [ "terminal" ]` — enabling `runtime_terminal` cascades to enable
`terminal`, which stays off by default and controls the underlying shell
relay. See `plugins/terminal/docs/syrus_docs/terminal.md` for the terminal
plugin itself and `config/syrus_docs/plugins.md`'s `:runtime_session_provider`
section for the general Runtime Session interface this plugin implements.

## What it provides

| Extension point | What it does |
|---|---|
| `:runtime_session_provider` | `RuntimeTerminal::Provider`, `provider_key: "cli_tui"`, `display_name: "Terminal"`. Starts a real worker-side terminal in the Coding Mode chat workspace, maps it to the generic `RuntimeSession` record, and speaks `Terminal::Relay`'s existing authenticated socket protocol for scrollback inspection and control-lease-gated input. |

## Composition, not reimplementation

`RuntimeTerminal::Provider#start_session` does not spawn a shell itself — it
creates a `Terminal::Session` (the same model the standalone `terminal`
plugin's operator-facing Terminal tab uses), enqueues the existing
`TerminalSessionJob`, and records the `RuntimeSession` ↔ `Terminal::Session`
pairing in a plugin-owned join table (`RuntimeTerminal::SessionLink`, table
`runtime_terminal_session_links`, one-to-one both ways via unique indexes on
`runtime_session_id` and `terminal_session_id`). The adapter intentionally
never modifies `terminal_sessions`, `Terminal::Session`, `Terminal::Relay`,
or `TerminalSessionJob` directly, and the link table carries no database
foreign key back into the `terminal` plugin's schema — the two plugins stay
independently deletable.

## Capabilities

`RuntimeTerminal::Provider.capabilities` advertises:

```ruby
{
  stream: "none",
  input: %w[keyboard stdin pointer resize],
  inspect: [ "scrollback" ],
  build: [ "none" ],
  artifacts: [ "logs" ]
}
```

Live streaming still goes through the `terminal` plugin's own UI path — the
Coding Mode Runtime panel renders `cli_tui` sessions with the same shared
xterm component and subscribes directly to `TerminalChannel` using the
mapped `Terminal::Session#id` from `metadata["terminal_session_id"]`, rather
than polling `runtime_logs`.

`.detect` always returns `false` — there is no auto-detection signal for
"this repository wants a CLI/TUI runtime session"; it is only ever chosen
explicitly (e.g. by `runtime_start(provider: "cli_tui")`).

## Relay protocol (`RuntimeTerminal::RelayClient`)

Each provider instance keeps a small pool of `RelayClient` sockets (one per
`runtime_session_id`, keyed in a class-level `Mutex`-guarded hash) that speak
`Terminal::Relay`'s newline-delimited JSON protocol directly over a
`TCPSocket`:

- **Connect** — raises `RelayClient::ConnectionError` if the mapped
  `Terminal::Session` isn't relay-ready yet or its `relay_address` doesn't
  parse as `host:port`.
- **Authenticate** — writes `{"token": "<terminal_session.auth_token>"}` as
  the first line.
- **Scrollback** (`#inspect_scrollback`) — accumulates `replay`/`output`
  frame payloads (base64-decoded) into an in-memory buffer as they arrive;
  `#inspect_scrollback` drains any newly-available bytes before returning
  the buffer.
- **Input** (`#input`) — translates a generic input event into one or more
  relay control frames:
  - `stdin` → the raw text, verbatim.
  - `keyboard`/`key` → either literal `data`/`text`, or a lookup table for
    named keys (`Enter`, `Tab`, `Backspace`, `Escape`, arrow keys, `Delete`,
    `Home`/`End`, `PageUp`/`PageDown`) mapped to their terminal escape
    sequences. An unrecognized key raises `RelayClient::UnsupportedInput`.
  - `resize` → a `{type: "resize", cols:, rows:}` frame; non-positive
    `cols`/`rows` raises `UnsupportedInput`.
  - `pointer`/`mouse`/`click`/`mousedown`/`mouseup`/`mousemove`/`wheel` →
    SGR mouse-tracking escape sequences (`\e[<code;x;y M/m`), covering
    click (press + release), down/up, move (drag), and wheel up/down.
    Positive `x`/`y` terminal coordinates are required; anything else
    raises `UnsupportedInput`.
- **Reconnection** — `Provider#with_fresh_relay_client` retries once through
  `Provider.replace_relay_client!` if the cached client reports `#closed?`
  or raises `RelayClient::ConnectionError` mid-call, covering the case where
  the underlying `Terminal::Session#relay_address` changed (e.g. the worker
  hosting the PTY restarted).

`#inspect` (the `RuntimeSessionProvider` interface method) blocks up to
`RELAY_ADDRESS_TIMEOUT` (10s), polling every `RELAY_ADDRESS_POLL_INTERVAL`
(0.2s), for `TerminalSessionJob` to publish a `relay_address` onto the
mapped `Terminal::Session` before attempting to connect.

## Input lease enforcement

`#input` refuses to even look up a relay client unless the `RuntimeSession`
holds an active agent input lease (`RuntimeSession#active_agent_input_lease`)
— the same `RuntimeControlLease` (DOC-17's Shared Human/Agent Control) every
other runtime provider's input path gates on. A rejected call is audited via
`RuntimeControlLease.audit_input_rejected!` and returns
`{error: "lease_required", ...}` instead of raising, matching the tool-level
contract `runtime_input` expects.

## Lifecycle

`#stop_session` closes the pooled relay client and, if the mapped
`Terminal::Session` is still running, marks it `finished_at: Time.current,
outcome: "killed"` — an already-finished session (e.g. the shell exited on
its own) is left untouched. `build_or_reload`, `launch`, and `snapshot` are
not supported by this provider and return `{error: "not_yet_supported", ...}`
rather than raising, since a bare shell has no separate build/launch step
and no visual snapshot to capture.

## Cleanup

`RuntimeTerminal::DataCleanup` installs an `always`-effect (runs even after
the plugin is disabled, as long as it was enabled at least once — see
`config/syrus_docs/plugins.md`'s "three states a plugin can be in") that
destroys any `RuntimeTerminal::SessionLink` row whose parent `RuntimeSession`
is destroyed, registered through `Syrus::DataCleanup`. This is `always`
rather than `while_enabled` specifically so disabling the adapter stops new
CLI/TUI runtime sessions from being created without orphaning link rows for
runtime sessions that already existed. It never touches the mapped
`Terminal::Session` itself — that row's lifecycle belongs entirely to the
`terminal` plugin.

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once
`gem "runtime_terminal", path: "plugins/runtime_terminal"` is bundled — no
manual `register!` call needed. Enabling it in Admin → Plugins also enables
its `terminal` dependency.
