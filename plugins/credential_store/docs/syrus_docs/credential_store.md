# Credential Store

The `credential_store` plugin owns generic credential records that should not
be added as one-off encrypted columns on `User`. It is installed and enabled
by default, and exposes broker-backed agent tools for generic credential
operations such as SSH command execution.

Operators manage records from **Credential Store** in the sidebar, or from
**Admin > Credential Store** when they are global admins. The page and
plugin-owned API list only safe metadata: credential type name, scope, target
constraints, rotation/revocation timestamps, and last-used audit metadata.
Payload material is write-only. Create, edit, and rotate forms accept new
secret material, but list/show responses never include existing payload
values.

`CredentialStore::Credential` stores `credential_type` as a lowercase type
name such as `ssh_private_key`, `token`, `json`, `env`, `file_blob`, or a
plugin-namespaced name such as `k8s_cluster.kubeconfig`, not as a storage
strategy. Every credential payload is kept in one Active Record Encryption
text column (`payload`), regardless of type. Display and probing data belongs
in `safe_metadata`, which only accepts a small allowlist of non-secret keys
such as `host`, `username`, `cluster`, `context`, `namespace`,
`fingerprint`, `known_host`, and `base_url`.

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

Credential types are strings. The store offers default types including
`ssh_private_key`, `token`, `json`, `env`, and `file_blob`, legacy
`credential_store.*` aliases, and type names declared by enabled plugins, such
as Kubernetes credential types from `k8s_cluster` when that plugin is enabled.
Plugins declare type names and safe descriptions only; they do not provide
payload forms, parsers, storage handlers, or authorization rules.

The plugin also owns append-only `CredentialStore::CredentialAccessEvent`
rows. Access events record which credential was used or denied, the actor and
runtime context when available (`user`, `repository`, `job`, `workflow`, `run`,
or `chat_session`), the tool/surface/action/purpose, result, and denial reason.
They intentionally do not store payload material. Credentials are
revocation-only at the model layer so destroying a credential cannot delete its
audit history.

## Brokered Tool Access

The plugin exposes a Ruby broker API for other bundled plugins that declare
`depends_on [ "credential_store" ]`. The broker is intentionally not an MCP
tool and never returns plaintext credential material to the agent:

```ruby
CredentialStore::Broker.with_credential_file(
  context: mcp_tool_context,
  credential: credential_id_or_name,
  type: "k8s_cluster.kubeconfig",
  purpose: "kubectl apply",
  tool_name: "k8s.apply",
  target: { kube_context: "production" }
) do |path, metadata|
  # Run the local command with the temporary file.
end

CredentialStore::Broker.with_credential_env(
  context: mcp_tool_context,
  credential: credential_id_or_name,
  type: "credential_store.url_token",
  env_key: "API_TOKEN",
  purpose: "probe deployment",
  tool_name: "deploy.probe",
  target: { host: "api.example.com", url: "https://api.example.com/status" }
) do |env, metadata|
  # Merge `env` into a child process environment.
end
```

Every broker call resolves the credential from the current `McpToolContext`,
then authorizes the request against credential scope, current user,
repository/team membership, allowed repository scope, MCP surface, allowed
tool name, expected credential type, target constraints, revocation, and
expiry. A successful call issues a short-lived local lease, materializes the
payload only inside the block as either a restrictive temporary file or a
per-call env hash, and cleans that local material in `ensure`.

Target constraints are deliberately small and broker-owned. Supported keys are
`allowed_hosts`, `allowed_url_prefixes`, `allowed_kube_contexts`,
`allowed_kube_clusters`, and `allowed_kube_namespaces`. Dependent tools pass a
target hash such as `host`, `url`, `kube_context`, `kube_cluster`, and
`kube_namespace`; the broker records allowed/denied audit rows without storing
payload material.

Broker return values and broker-wrapped exceptions are scrubbed with
`CredentialStore::Redaction`, which removes the known credential payload and
common unsafe probe output shapes before a dependent MCP tool returns results
or persistent dispatch records an error summary. Dependent tools should still
avoid printing command environments or raw files; the broker is the last guard,
not a substitute for careful tool design.

## SSH MCP Tools

`credential_store_ssh_exec` is available to workflow agents and as a deferred
chat tool when the plugin is enabled. It accepts a credential id or name,
`host`, `user`, optional `port`, and a remote `command`. The tool requests an
`ssh_private_key` broker lease, materializes the key into a temporary `0600`
file only for the duration of the SSH process, and returns sanitized
`stdout`, `stderr`, and exit status. Payloads may be a raw private key or JSON
with `private_key` and optional `passphrase`; passphrases are passed through a
temporary askpass helper and redacted from results.

Use target policy on SSH credentials:

- Set `safe_metadata.host` and `safe_metadata.username` when a key belongs to
  one target account.
- Set `target_constraints.allowed_hosts` for host allowlists.
- Set `safe_metadata.known_host` to a full public known-hosts line when the
  tool must enforce a specific host key.
- Set `safe_metadata.fingerprint` for operator-visible fingerprint tracking;
  use `known_host` when the tool must enforce host identity.

The tool refuses credentials that have no host, known-host, or `allowed_hosts`
constraint unless a workflow caller explicitly sets
`allow_unconstrained_host: true`. Commands matching obviously destructive
patterns are refused unless a workflow caller supplies
`allow_risky_command: true`. Chat-surface calls cannot self-authorize either
bypass; they fail instead of executing. All access attempts are audited by the
broker, including denials for revoked credentials, wrong credential types,
surface/tool policy mismatches, SSH metadata mismatches, unconstrained
credentials, and target constraint failures.
