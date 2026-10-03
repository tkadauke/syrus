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

## CLI

The bundled `syrus` binary includes a static `credential` namespace owned by
this plugin. `credential_store` remains an alias for older scripts:

```bash
syrus credential types
syrus credential credentials
syrus credential credentials --type credential_store.url_token
syrus credential lease deploy-token \
  --type credential_store.url_token \
  --purpose deploy \
  --tool deploy.push \
  --target-json '{"host":"api.example.com"}'
syrus credential exec \
  --credential deploy-token \
  --type credential_store.url_token \
  --env-var SERVICE_TOKEN \
  -- ./script.sh
syrus credential exec \
  --credential kubeconfig \
  --type credential_store.kubeconfig \
  --file-env KUBECONFIG \
  -- kubectl get pods
syrus credential exec \
  --credential signing-token \
  --type credential_store.generic \
  --stdin \
  -- ./read-token-from-stdin.sh
syrus credential ssh-agent --credential homeassistant-ssh -- ./deploy.sh
```

`types` and `credentials` are discovery commands over the same app API used by
the management page. They return credential type declarations, accessible
credential ids/names, scope labels, safe metadata, target constraints, allowed
surfaces/tools, and active/revoked/expiry status. They do not return payload
material.

`lease` is only available inside a Syrus-managed runtime authenticated by
`SYRUS_CLI_INVOCATION_CONTEXT`; a normal saved CLI API token receives a
forbidden response. The command asks the existing broker for a scoped lease
using the current run/chat context, records the normal credential access audit
row, and prints lease metadata such as lease id, credential id/name/type, safe
metadata, purpose, tool, and expiry. The response intentionally omits the
credential payload.

`exec` is also runtime-only and is for bespoke scripts that need non-SSH
credential material in a tightly scoped process-local form. The caller must
choose exactly one materialization mode: `--env-var NAME` exports the payload
as `NAME` for the child process, `--file-env NAME` writes it to a temporary
`0600` file outside the repository and exports that path as `NAME`, and
`--stdin` provides the payload as the child process standard input. The wrapper
uses the same broker authorization, target constraints, and access audit rows
as `lease`, then records a completion audit row with the lease id, mode, exit
status, and duration. It removes temporary files after the child process exits,
does not print command previews containing credential-derived values, and
redacts the exact payload from child stdout/stderr before streaming it back.
There is intentionally no mode that echoes plaintext credentials or writes them
to a caller-selected persistent path.

`ssh-agent` is also runtime-only. It requests an `ssh_private_key` lease,
starts a short-lived local `ssh-agent`, writes the private key only to a
temporary `0600` file long enough to run `ssh-add`, exports `SSH_AUTH_SOCK` to
the child command, and tears down the agent plus temp files on success or
failure. Payloads may be a raw private key or JSON with `private_key` and
optional `passphrase`; passphrases are supplied through a temporary askpass
helper and are not passed to the child command. The wrapper records a
completion audit row with the lease id, credential handle, current
job/workflow/run/repository/user context, wrapper command namespace, child exit
status, and duration. It does not print private keys, passphrases, raw payload
material, or child command arguments.

## Repository-Owned Script Policy

Repository-owned deploy/debug scripts should call credential wrappers from the
script command line rather than reading secrets from the agent environment or
from committed config. For a Home Assistant-style SSH deploy, the preferred
shape is:

```bash
syrus credential ssh-agent \
  --credential homeassistant-ssh \
  --purpose deploy \
  --target-json '{"host":"ha.example.com"}' \
  -- ./deploy.sh
```

For non-SSH material, use `syrus credential exec` with exactly one
materialization mode:

```bash
syrus credential exec \
  --credential deploy-api-token \
  --type credential_store.url_token \
  --env-var SERVICE_TOKEN \
  --purpose deploy \
  --target-json '{"host":"api.example.com"}' \
  -- ./deploy.sh
```

Agents may invoke a wrapper from a Job or chat-assisted runtime only when all
of these are true:

- The repository declares the script intent in `.syrus.yml` `scripts:` or the
  operator gives an equivalent explicit instruction in the current trusted
  context.
- The declaration or instruction names a credential handle, type, wrapper,
  purpose, and target metadata; it never includes payload material.
- The credential is scoped so the current user/repository/team/instance context
  can use it, and its `allowed_surfaces`, `allowed_tools`, type, target
  constraints, expiry, and revocation state authorize the requested wrapper.
- The agent is running inside Syrus runtime authentication
  (`SYRUS_CLI_INVOCATION_CONTEXT`), not from a human's local
  `~/.syrus/credentials`.
- The child command matches the declared repository script intent. If the
  script is undeclared or `allow_agent_invocation` is false, ask an operator
  before running it.

The `.syrus.yml` declaration is policy metadata, not a capability grant:

```yaml
scripts:
  deploy:
    run: ./deploy.sh
    description: Deploy the Home Assistant appliance.
    allow_agent_invocation: true
    credentials:
      - name: ssh
        credential: homeassistant-ssh
        type: ssh_private_key
        wrapper: ssh-agent
        purpose: deploy
        tool: credential.ssh-agent
        target:
          host: ha.example.com
```

The credential handle is a stable name or id for lookup. The encrypted payload
stays in `credential_store`; do not put private keys, tokens, passphrases, or
inline kubeconfigs in `.syrus.yml`.

Operator setup flow:

1. Create the credential in Credential Store with the appropriate type, such as
   `ssh_private_key` for `ssh-agent` or `credential_store.url_token` for
   `exec`.
2. Scope it as narrowly as possible: user-scoped for a personal workflow,
   repository-scoped for one repo, team-scoped for a team-owned fleet, or
   instance-scoped only for shared operational credentials.
3. Add safe metadata and target constraints such as `host`,
   `allowed_hosts`, `base_url`, or `allowed_url_prefixes`.
4. Set `allowed_surfaces` to the intended runtime, usually `workflow` for Jobs
   and optionally `chat` for chat-assisted runs.
5. Set `allowed_tools` to the wrapper namespace, such as
   `credential.ssh-agent` or `credential.exec`.
6. Commit a `.syrus.yml` `scripts:` entry that names the handle and wrapper,
   then invoke the wrapper command from the deploy/debug script or from the
   trusted runtime instruction.

Transcripts and audits should show the wrapper command namespace, credential
handle, type, purpose, target metadata, exit status, and timing. They must not
show plaintext credential payloads, passphrases, temporary file contents, or
runtime invocation tokens. The CLI removes temporary material after the child
process exits and redacts the exact payload from child stdout/stderr before it
is streamed back.

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
