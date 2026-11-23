# Mail adapters

The experimental, default-disabled Mail plugin owns provider-neutral `mail_search` and
`mail_read_message` tools. Adapter plugins implement the provisional `mail` capability
family's keyed `search` and `read_message` capabilities and declare their provider key.
Both receive a `SyrusMail::Context` containing the account, short-lived broker access object,
and normalized arguments. They must return hashes and must never return or persist token
material. The concept layer marks results `external_untrusted`, strips markup, and moves
large bodies and every attachment into workspace files.

Adapters can use `SyrusMail::FakeAdapter` and set its `messages` collection in contract tests.
Each message uses string keys; full messages may contain `body` and `attachments`, where
an attachment has `filename` and `content`.
