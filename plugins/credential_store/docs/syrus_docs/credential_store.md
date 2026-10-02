# Credential Store

The `credential_store` plugin owns generic credential records that should not
be added as one-off encrypted columns on `User`. It is installed and enabled
by default, but it does not expose agent tools by itself.

`CredentialStore::Credential` stores `credential_type` as a lowercase,
dot-separated plugin credential type name such as `k8s_cluster.kubeconfig`,
not as a storage strategy. Every credential payload is kept in one Active
Record Encryption text column (`payload`), regardless of type. Display and
probing data belongs in `safe_metadata`, which only accepts a small allowlist
of non-secret keys such as `host`, `username`, `cluster`, `context`,
`fingerprint`, and `base_url`.

Scopes use existing Syrus ownership entities:

- `user` scope references `User`.
- `repository` scope references `Repository`.
- `team` scope references `Team`.
- `instance` scope has no `scope_id`.

The plugin also owns append-only `CredentialStore::CredentialAccessEvent`
rows. Access events record which credential was used or denied, the actor and
runtime context when available (`user`, `repository`, `job`, `workflow`, `run`,
or `chat_session`), the tool/surface/action/purpose, result, and denial reason.
They intentionally do not store payload material. Credentials are
revocation-only at the model layer so destroying a credential cannot delete its
audit history.
