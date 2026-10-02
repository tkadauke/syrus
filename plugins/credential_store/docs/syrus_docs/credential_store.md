# Credential Store

The `credential_store` plugin owns generic credential records that should not
be added as one-off encrypted columns on `User`. It is installed and enabled
by default, but it does not expose agent tools by itself.

Operators manage records from **Admin > Credential Store**. The page and
plugin-owned API list only safe metadata: credential type name, scope, target
constraints, rotation/revocation timestamps, and last-used audit metadata.
Payload material is write-only. Create, edit, and rotate forms accept new
secret material, but list/show responses never include existing payload
values.

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

Management authorization follows the same scopes:

- A user may manage their own user-scoped credentials.
- A repository admin may manage credentials scoped to that repository.
- A team owner may manage credentials scoped to that team.
- Only global admins may manage instance-scoped credentials.

Credential types are strings. The store offers default
`credential_store.*` types and also lists type names declared by enabled
plugins, such as Kubernetes credential types from `k8s_cluster` when that
plugin is enabled. Plugins declare type names and safe descriptions only; they
do not provide payload forms, parsers, storage handlers, or authorization
rules.

The plugin also owns append-only `CredentialStore::CredentialAccessEvent`
rows. Access events record which credential was used or denied, the actor and
runtime context when available (`user`, `repository`, `job`, `workflow`, `run`,
or `chat_session`), the tool/surface/action/purpose, result, and denial reason.
They intentionally do not store payload material. Credentials are
revocation-only at the model layer so destroying a credential cannot delete its
audit history.
