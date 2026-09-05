# K8s Cluster Viewer

The `k8s_cluster` plugin (`plugins/k8s_cluster/`) lets an operator register
external Kubernetes/k3s clusters and manage their connections from an
admin-only sidebar page. It is a self-contained Rails engine plugin,
installed but disabled by default (`default_enabled: false`,
`disableable: true`, category `tooling`) - the plugin's own
`PluginRecord.enabled` toggle is the feature gate, same as
`mysql_db_browser`. There is no separate `Feature` flag. Every controller
action checks `K8sCluster.enabled?` and `Current.user.admin?`.

This first Job scaffolds connection management only: register a cluster
from a pasted kubeconfig, test the connection, edit, and delete. Read-only
resource browsing (namespaces, pods, deployments, services, events, logs,
PVCs, nodes, CronJobs, metrics) and gated agentic access are follow-up work
per EPIC-306 / DOC-21 - this plugin has no cluster-resource browsing and no
MCP tool sets yet.

## Clusters (`KubernetesCluster`)

`app/models/kubernetes_cluster.rb` stores `label`, `api_server_url`, and
encrypted `credentials` (`encrypts :credentials`, same pattern as
`MysqlConnection#credentials` and `InputSource#credentials`: an
`attribute :credentials, :json` cast backed by a `t.text` column, since
MySQL cannot store ciphertext in a genuine JSON column, plus an
`after_initialize` seed to `{}` - never a DB-level default, since JSON
columns can't have one on MySQL 8). The plaintext token or client
certificate/key lives only inside that encrypted blob, never in a plain
column. Three independent booleans, all default `false`:

- `agentic_access_enabled` - reserved for a later Job that adds MCP tools
  mirroring `mysql_db_browser`'s per-connection agentic gating. Not wired to
  anything yet.
- `allow_writes` - reserved the same way, for the narrowly scoped write
  actions DOC-21 describes.
- `insecure_skip_tls_verify` - skips TLS certificate verification when
  connecting to the cluster's API server, for self-signed k3s API servers.
  Always defaults to `false` and is rendered as a clearly-labeled opt-in
  checkbox on the connection form; it is never inferred from a pasted
  kubeconfig.

Managed from **Admin -> K8s Clusters** (`/k8s_clusters`, admin-only sidebar
page, `K8sCluster::SidebarPages`) via `GET/POST/PATCH/DELETE
/api/v1/app/admin/kubernetes_clusters` and a connect-test endpoint
(`POST .../test` or `.../:id/test`, backed by `K8sCluster::ConnectionTester`)
that never persists a draft cluster.

## Kubeconfig parsing (`K8sCluster::KubeconfigParser`)

The create/update actions never accept `api_server_url` or credential
fields directly - only a pasted `kubeconfig` YAML string (as the
`kubernetes_cluster[kubeconfig]` param). `KubeconfigParser.parse(yaml)`:

1. Parses the YAML (`YAML.safe_load`, permitting `Date`/`Time`) and requires
   a `current-context`.
2. Resolves that context's `cluster` and `user` entries by name.
3. Extracts `cluster.server` as `api_server_url`.
4. Extracts whichever of the user's credentials are present: a bearer
   `token`, or `client-certificate-data` + `client-key-data` (both must be
   present together). `cluster.certificate-authority-data`, when present, is
   attached to the credentials hash as `ca_data` regardless of which user
   auth type was used.
5. Raises `KubeconfigParser::ParseError` with a specific, user-facing
   message for every unresolvable case: blank/invalid YAML, a missing or
   unmatched `current-context`/cluster/user reference, a cluster with no
   `server`, an `exec`-based credential plugin (aws-iam-authenticator,
   gke-gcloud-auth-plugin, etc. - Syrus cannot run those), or credentials
   that reference external files (`client-certificate`, `client-key`,
   `tokenFile`) instead of inline `-data` fields.

Only the resolved single-cluster connection info is ever persisted - the
raw, possibly multi-context kubeconfig blob is discarded after parsing. On
`create`, a kubeconfig is required. On `update`, omitting `kubeconfig`
leaves the cluster's existing `api_server_url`/credentials untouched (the
same "leave blank to keep the current value" pattern
`MysqlConnectionsController` uses for password rotation); supplying a new
one re-parses and replaces both.

## Connection testing (`K8sCluster::ConnectionTester`)

`ConnectionTester` attempts a lightweight, unauthenticated-shape `GET
/version` against the cluster's API server using Faraday, mirroring
`MysqlDbBrowser::ConnectionTester`'s shape (a stubbable `connection_factory`
class attribute, `.test(cluster)` for a persisted row, `.test_params(...)`
for a draft). It never persists anything. SSL options are built per call:

- `verify: !insecure_skip_tls_verify`.
- A client certificate/key pair (`OpenSSL::X509::Certificate` /
  `OpenSSL::PKey.read`, both Base64-decoded from the stored kubeconfig
  `-data` fields) when the cluster authenticates via client cert.
- A `cert_store` built from `ca_data`, when present, so a cluster with a
  private CA verifies without needing `insecure_skip_tls_verify`.

A bearer token, when present, is sent as an `Authorization: Bearer <token>`
header. `test_connection` reports `{ success: true }` on any successful HTTP
response, or `{ success: false, error: "..." }` on an HTTP error status,
raised `Faraday::Error`, or an `OpenSSL` error (bad certificate/key data) -
it never raises out to the controller.

## What's not here yet

Per DOC-21's phased plan, this Job intentionally stops at connection
management. Later Jobs under EPIC-306 add: read-only cluster-resource
browsing (namespaces, pods, deployments, services, events, logs, PVCs,
nodes, CronJobs, CPU/memory via metrics-server) on the sidebar page, and
gated agentic access via `mcp_tool_set`/`chat_mcp_tool_set` MCP tools keyed
off `agentic_access_enabled`/`allow_writes`, the same shape
`mysql_db_browser` uses for its own MCP tool sets.
