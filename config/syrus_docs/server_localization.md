# Server localization

Server-rendered and JSON-facing product copy uses Rails I18n with matching
keys in `config/locales/en.yml`, `de.yml`, and `la.yml`. Keep keys under the
owning surface (`api`, `models`, `services`, `pending_actions`, `admin`, or
`mcp`); `server.errors` holds genuinely shared fallback copy. Serializers and
services receive the ambient locale rather than selecting one themselves.

Authenticated controllers run inside `ApplicationController#switch_locale`,
which selects `Current.user.locale`. A controller therefore translates at the
last responsible moment. Work that outlives a request must capture the user's
locale as an explicit job/action argument and wrap user-visible rendering in
`I18n.with_locale`; system-wide background work uses `I18n.default_locale`.
Mailers receive locale explicitly through `.with(locale: ...)`. Never depend
on thread-local locale leaking from an earlier request or job.

API failures use `render_error(code, translated_message, status:)`. Its stable
shape is `{ "error": { "code": "machine_token", "message": "..." } }`.
Clients branch on `code`, never translated `message`. Existing endpoint codes
and envelopes are compatibility contracts and must not be renamed while copy
is migrated.

`spec/i18n/ruby_source_debt_spec.rb` audits direct `render_error` copy,
user-visible `message`/`notice`/`alert` fields, `errors.add`, and labels emitted
by serializers/presenters. Its reviewed manifest is a debt ceiling: pay counts
down, never increase it. Logs, exceptions, commands, protocol tokens, external
payloads, and diagnostics are deliberately outside this user-visible audit.

German copy addresses the operator with informal *du*, retains Job, Workflow,
and Epic, and calls a Run *Lauf* (plural *Läufe*, including *Agentenlauf*).
Repository, Issue, and Polling follow the established catalog usage. Latin
keeps the existing domain nouns until the pending entries in the
[core localization glossary](../../docs/i18n-glossary.md) receive competent
review; implementation must not normalize Latin domain nouns before that
approval. Ordinary grammar and accidental English should still be corrected.
