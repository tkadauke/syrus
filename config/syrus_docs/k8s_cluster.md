# K8s Cluster Viewer

The `k8s_cluster` plugin (`plugins/k8s_cluster/`) lets an operator register
external Kubernetes/k3s clusters and manage their connections from an
admin-only sidebar page. It is a self-contained Rails engine plugin,
installed but disabled by default (`default_enabled: false`,
`disableable: true`, category `tooling`) - the plugin's own
`PluginRecord.enabled` toggle is the feature gate, same as
`mysql_db_browser`. There is no separate `Feature` flag. Every controller
action checks `K8sCluster.enabled?` and `Current.user.admin?`.

The foundation Job scaffolded connection management: register a cluster
from a pasted kubeconfig, test the connection, edit, and delete. This Job
adds the read-only Kubernetes API client, one service object per resource
kind, and the JSON API endpoints those services back - namespaces, pods
(including per-container log tail), deployments, services, events,
PersistentVolumeClaims, nodes, CronJobs, and a cluster overview backed by
the `metrics.k8s.io` API. Gated agentic access (MCP tools) and the
sidebar-page browsing UI that consumes these endpoints are follow-up work
per EPIC-306 / DOC-21 - see "What's not here yet" below.

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

## Kubernetes API client (`K8sCluster::ApiClient`)

`K8sCluster::ApiClient` builds authenticated `Kubeclient::Client` instances
(the `kubeclient` gem) per Kubernetes API group for a `KubernetesCluster`:
`#core` (`/api`, `v1` - namespaces, pods, services, events,
PersistentVolumeClaims, nodes), `#apps` (`apis/apps/v1` - deployments),
`#batch` (`apis/batch/v1` - CronJobs), and `#metrics`
(`apis/metrics.k8s.io/v1beta1` - see Overview below). Each client is built
with `as: :parsed`, so entity calls (`get_pods`, `get_deployment`, ...) hand
back plain parsed JSON hashes instead of `RecursiveOpenStruct` wrappers -
resource services just dig into hashes, the same style as the rest of
Syrus. Credentials translate the same way `ConnectionTester` already does:
a bearer token becomes `auth_options: { bearer_token: }`; client
cert/key and CA data are base64-decoded into `OpenSSL::X509::Certificate` /
`OpenSSL::PKey` / `OpenSSL::X509::Store` `ssl_options`; `insecure_skip_tls_verify`
maps to `OpenSSL::SSL::VERIFY_NONE`. Clients are memoized per `ApiClient`
instance, one per Kubernetes API group, but a fresh `ApiClient` (and fresh
Kubeclient discovery round-trip - see below) is built per request; there is
no persistent connection pool.

Kubeclient (4.x) discovers each API group's available resources lazily -
the first `get_pods`/`get_deployments`/etc. call against a freshly built
client triggers a `GET` against the group's own root (e.g. `/api/v1` or
`/apis/apps/v1`) to fetch its `APIResourceList` before dispatching the
actual entity request. Service specs stub both requests against a fake API
server via WebMock (`plugins/k8s_cluster/spec/support/kube_api_stubs.rb`) -
no real cluster involved.

## Resource services (one per Kubernetes kind)

Mirroring `mysql_db_browser`'s schema/query service split, each Kubernetes
resource kind gets its own read-only service class under
`K8sCluster::`, all inheriting from `K8sCluster::ResourceService` (shared
`Unavailable`/`NotFound` errors, mapped from `Kubeclient::ResourceNotFoundError`/
`Kubeclient::HttpError` plus raw connection failures - timeouts, TLS errors,
DNS/connection-refused - the same two-outcome shape `SchemaInspector` uses):

- `Namespaces`, `Nodes` - cluster-scoped: `#list` and `#describe(name)`.
- `Pods`, `Deployments`, `Services`, `PersistentVolumeClaims`, `CronJobs` -
  namespace-scoped: `#list(namespace: nil)` (omitting `namespace` lists
  across every namespace, matching `kubectl get <kind> -A`) and
  `#describe(name, namespace:)` (namespace is required to describe a single
  object, since Kubernetes has no cross-namespace "get by name" for these
  kinds). `Pods` additionally has `#logs(name, namespace:, container: nil,
  tail_lines: 200, previous: false, timestamps: false)` for a per-container
  log tail (`Kubeclient#get_pod_log`) - `container` is required once a pod
  has more than one container, the same way the raw Kubernetes API itself
  requires it.
- `Events` - namespace-scoped, `#list(namespace: nil)` only; an individual
  Event has no useful "describe" beyond its list row. Sorted
  most-recent-first by `lastTimestamp`/`eventTime`/`firstTimestamp`.

`#list` returns a compact summary row per item (name/namespace plus the
handful of fields a browsing table needs - phase, ready count, replica
counts, capacity, schedule, etc.); `#describe` returns the full raw parsed
Kubernetes object under a single key (`pod:`, `deployment:`, ...) rather
than a curated subset, since a "describe" view is meant to show everything
`kubectl get -o json` would. Every list/describe payload is wrapped with
`available: true, generated_at:` (and `truncated:` for list, capped at 500-
1000 rows depending on kind) so the shape matches `SchemaInspector`'s
sections.

## Cluster overview / metrics (`K8sCluster::Overview`)

`Overview#call` queries the `metrics.k8s.io` API (via `ApiClient#metrics`)
for aggregate node and pod CPU/memory, returning
`{ generated_at:, nodes: {...}, pods: {...} }`. Because `metrics.k8s.io`
is an aggregated API with only "nodes"/"pods" resources (no create/update/
etc.) and often isn't installed at all (a bare k3s box, a fresh cluster),
`Overview` bypasses Kubeclient's entity-method discovery entirely and hits
the REST path directly via the client's own public `rest_client`/
`get_headers` (`client.rest_client["nodes"].get(client.get_headers)`).
CPU/memory quantity strings (`"250m"`, `"23148330n"`, `"512Mi"`,
`"128974848"`) are parsed by `K8sCluster::ResourceQuantity` into millicores
and bytes so per-item and aggregate totals can be summed and compared.

Any failure fetching either resource - metrics-server not installed (a 404
from the aggregation layer), any other HTTP error, or a connection failure -
soft-fails to `{ available: false, reason: "metrics_unavailable", message:
"..." }` for that resource. `Overview` never raises: this is the same
soft-fail posture the `prepare` step uses for guessed commands (CLAUDE.md) -
a cluster with no metrics-server is a normal, expected configuration, not
an error condition the operator needs a 502 for.

## JSON API endpoints

`Api::V1::App::Admin::KubernetesResourcesController`, admin-only (inherits
`Admin::BaseController`'s `require_admin`), resolves the `KubernetesCluster`
by `:id` per request exactly like `MysqlSchemaController`/`MysqlQueryController`
resolve a `MysqlConnection`, and 404s with `plugin_disabled` when the plugin
itself is off:

```
GET .../kubernetes_clusters/:id/namespaces[?name=]
GET .../kubernetes_clusters/:id/pods[?namespace=][?name=&namespace=]
GET .../kubernetes_clusters/:id/pods/:name/logs?namespace=[&container=&tail_lines=&previous=&timestamps=]
GET .../kubernetes_clusters/:id/deployments[?namespace=][?name=&namespace=]
GET .../kubernetes_clusters/:id/services[?namespace=][?name=&namespace=]
GET .../kubernetes_clusters/:id/events[?namespace=]
GET .../kubernetes_clusters/:id/pvcs[?namespace=][?name=&namespace=]
GET .../kubernetes_clusters/:id/nodes[?name=]
GET .../kubernetes_clusters/:id/cronjobs[?namespace=][?name=&namespace=]
GET .../kubernetes_clusters/:id/overview
```

Each namespace-scoped/cluster-scoped resource kind is a single route: a
`name` param switches that same action from list to describe (cluster-scoped
kinds need only `name`; namespace-scoped kinds need `name` **and**
`namespace` together, rejected with `422 namespace_required` otherwise) -
one route per resource kind, matching the plugin's declared route list
one-for-one, rather than a separate nested `/:name` route per kind.
`ResourceService::Unavailable` renders `502 connection_unavailable`;
`ResourceService::NotFound` renders `404 not_found`.

## What's not here yet

Per DOC-21's phased plan, this Job stops at the API client, resource
services, and JSON endpoints - no sidebar-page UI consumes them yet, and
there are no MCP tools. Later Jobs under EPIC-306 add: a tabbed
cluster-browsing UI on the sidebar page (Overview/Workloads/Services/
Storage/Nodes/Events/Logs/Live tabs, per DOC-21) consuming these same
endpoints, and gated agentic access via `mcp_tool_set`/`chat_mcp_tool_set`
MCP tools keyed off `agentic_access_enabled`/`allow_writes`, the same shape
`mysql_db_browser` uses for its own MCP tool sets.
