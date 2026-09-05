# K8s Cluster Viewer

The `k8s_cluster` plugin (`plugins/k8s_cluster/`) lets an operator register
external Kubernetes/k3s clusters and manage their connections from an
admin-only sidebar page. It is a self-contained Rails engine plugin,
installed but disabled by default (`default_enabled: false`,
`disableable: true`, category `tooling`) - the plugin's own
`PluginRecord.enabled` toggle is the feature gate, same as
`mysql_db_browser`. There is no separate `Feature` flag. Every controller
action checks `K8sCluster.enabled?` and `Current.user.admin?`.

The foundation Jobs scaffolded connection management (register a cluster
from a pasted kubeconfig, test the connection, edit, and delete), the
read-only Kubernetes API client - one service object per resource kind, and
the JSON API endpoints those services back: namespaces, pods (including
per-container log tail), deployments, services, events,
PersistentVolumeClaims, nodes, CronJobs, and a cluster overview backed by
the `metrics.k8s.io` API. A follow-up Job added the tabbed cluster-browsing
UI that consumes those endpoints - see "Cluster-browsing UI" below, then a
further Job added gated, read-only agentic access (MCP tools) - see "Agentic
access" below. This Job adds a short, explicit allowlist of write/mutating
MCP tools - restart a deployment rollout, scale a deployment, delete a pod,
cordon/uncordon a node - gated by a separate, stricter `allow_writes` opt-in
per DOC-21 phase 2; see "Write-capable agentic tools" and "Minimal RBAC for
agentic access" below.

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
- `Pods`, `Deployments`, `Services`, `Endpoints`, `PersistentVolumeClaims`,
  `CronJobs` - namespace-scoped: `#list(namespace: nil)` (omitting
  `namespace` lists across every namespace, matching `kubectl get <kind>
  -A`) and `#describe(name, namespace:)` (namespace is required to describe
  a single object, since Kubernetes has no cross-namespace "get by name" for
  these kinds). `Pods` additionally has `#logs(name, namespace:, container:
  nil, tail_lines: 200, previous: false, timestamps: false)` for a
  per-container log tail (`Kubeclient#get_pod_log`) - `container` is
  required once a pod has more than one container, the same way the raw
  Kubernetes API itself requires it. `Pods#list`'s summary row also includes
  `container_names` (from `spec.containers`) so the browsing UI's Logs tab
  can populate a container picker without a second request. `Nodes#list`'s
  summary row includes `allocatable_cpu`/`allocatable_memory` alongside
  `capacity_cpu`/`capacity_memory` (from `status.allocatable`). `Endpoints`
  summarizes each object's `ready_addresses`/`not_ready_addresses` counts
  (summed across `subsets`) and its ports - by core v1 API convention an
  Endpoints object shares its Service's `(namespace, name)`, which is how
  the Services tab pairs the two without a separate lookup field; a Service
  with no selector (e.g. `ExternalName`) simply has no matching Endpoints
  row, which the UI treats as "not applicable" rather than an error.
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
GET .../kubernetes_clusters/:id/endpoints[?namespace=][?name=&namespace=]
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

## Cluster-browsing UI

**Admin -> K8s Clusters** now has a **Browse** action per row (next to
**Test**/**Edit**/**Delete**) that opens a tabbed, read-only viewer for that
cluster (`plugins/k8s_cluster/app/frontend/components/ClusterBrowser.tsx`),
mirroring `mysql_db_browser`'s connections-list-to-schema-browser flow:

- **Overview** - node count and ready/not-ready status (from `Nodes#list`)
  plus aggregate node/pod CPU and memory (from `Overview#call`), with a
  graceful "metrics unavailable" message per section instead of an error
  when `metrics.k8s.io` isn't installed.
- **Workloads** - a workload-kind switcher (Pods/Deployments/CronJobs) over
  the shared namespace filter, with status/ready/restart-count (pods),
  ready/available/updated replica counts (deployments), or
  schedule/suspended/active-count (CronJobs) columns, plus an age column
  computed client-side from `created_at`.
- **Services** - namespaced services with type, cluster IP, and ports, plus
  an Endpoints column (fetched alongside, paired by `(namespace, name)`)
  showing ready/not-ready backing-address counts; a Service with no matching
  Endpoints row (e.g. `ExternalName`) shows a dash, and an Endpoints fetch
  failure degrades that column to a dash instead of failing the whole tab.
  Kubernetes' newer `EndpointSlice` API is not fetched - the older
  `Endpoints` object covers the same summary-level readiness data this tab
  needs.
- **Storage** - PersistentVolumeClaims with bound status, capacity, and
  storage class.
- **Nodes** - the cluster-scoped node list with readiness, roles,
  capacity, and allocatable capacity.
- **Events** - namespaced/cluster events as returned by `Events#list`
  (already sorted most-recent-first server-side).
- **Logs** - a pod picker (scoped by the shared namespace filter) and,
  once a pod with more than one container is selected, a container picker
  populated from that pod's `container_names`; fetches a fixed 200-line
  tail per `Pods#logs` and offers a manual Refresh button rather than
  auto-polling.
- **Live** - a polling tab over two canned queries (pod status, recent
  events) with a 10s `refetchInterval`, directly mirroring
  `plugins/mysql_db_browser/app/frontend/components/MysqlLiveTab.tsx`'s
  canned-query shape rather than a bespoke live feed.

A shared namespace filter (`ClusterBrowser`'s `NamespacePicker`, populated
from `Namespaces#list`) appears only for the namespace-scoped tabs
(Workloads/Services/Storage/Events/Logs); Overview and Nodes are always
cluster-wide. The top-level tab switcher and the namespace/workload-kind/
pod/container pickers all use the same toolbar dropdown control
(`components/Dropdown.tsx`, a button+listbox pattern) per CLAUDE.md's
convention for small fixed-choice toolbar controls - never a native
`<select>` for this kind of in-page switcher. All frontend strings are
translated across `en`/`de`/`la` (`app/frontend/i18n/locales/*/k8s_cluster.json`).

## Agentic access

Each `KubernetesCluster` carries its own `agentic_access_enabled` opt-in
(surfaced as a checkbox on the connection create/edit form, default `false`),
independent of the plugin's own enable/disable toggle. When set, that
specific cluster becomes browsable read-only by workflow and chat agents
through eleven read-only MCP tools (plus four write tools gated separately -
see "Write-capable agentic tools" below) exposed via `mcp_tool_set`/`chat_mcp_tool_set`
(`K8sCluster::WorkflowToolSet` / `K8sCluster::ChatToolSet`,
`plugins/k8s_cluster/app/services/k8s_cluster/{workflow,chat}_tool_set.rb`),
mirroring `mysql_db_browser`'s own MCP tool sets:

- `k8s_cluster_list_clusters` - lists registered clusters using safe
  metadata only: `id`, `label`, `agentic_access_enabled`, `allow_writes`,
  `created_at`, and `updated_at`. It deliberately omits `api_server_url` and
  all credential fields. Agents should call this first to discover the
  correct `cluster_id` before using any other tool.
- `k8s_cluster_namespaces` / `k8s_cluster_nodes` - list or describe the two
  cluster-scoped kinds. Omitting `name` lists; passing `name` describes that
  one object.
- `k8s_cluster_pods` / `k8s_cluster_deployments` / `k8s_cluster_services` /
  `k8s_cluster_pvcs` / `k8s_cluster_cronjobs` - list or describe the
  namespace-scoped kinds. Omitting `namespace` lists across every namespace
  (matching `kubectl get <kind> -A`); passing `name` describes a single
  object and requires `namespace` alongside it (rejected with a
  `namespace is required` tool error otherwise) - the same list-vs-describe
  contract `KubernetesResourcesController` uses for the browsing UI's
  endpoints.
- `k8s_cluster_events` - list-only, `namespace` optional, most-recent-first
  (an individual Event has no useful describe beyond its list row).
- `k8s_cluster_pod_logs` - a pod's log tail via `Pods#logs`; `container` is
  required once a pod has more than one container, `tail_lines` defaults to
  200, and `previous`/`timestamps` pass through to the same Kubernetes API
  flags the Logs tab uses.
- `k8s_cluster_overview` - the aggregate CPU/memory metrics overview via
  `Overview#call`; soft-fails per-section (`available: false`) rather than
  erroring when `metrics-server` isn't installed, same as the UI's Overview
  tab.

Every tool call takes a `cluster_id` param and every read wraps the matching
`K8sCluster::` resource service directly (`Namespaces`, `Pods`,
`Deployments`, `Services`, `Events`, `PersistentVolumeClaims`, `Nodes`,
`CronJobs`, `Overview`) - no separate agentic-only code path, so the agent
sees exactly what the browsing UI sees.

**Gating is per-cluster, not per-repository or admin-only.** There is no
framework hook to resolve an individual tool call's params from
`available_for?`/`available_for_context?` - those are only checked once, at
MCP manifest-build time, before any call happens. So `available_for?`/
`available_for_context?` only decide whether the tool set appears in the
manifest at all (plugin enabled, `WORKFLOW_IMPLEMENT` role for workflow
runs, and at least one configured `KubernetesCluster` so an agent can
inspect safe cluster metadata); the actual per-cluster authorization happens
inside each tool's own `#call`, via `K8sCluster::AgenticAccess.cluster!(id)` -
it resolves the `cluster_id` named in that call's params and raises unless
that specific row has `agentic_access_enabled: true`, mirroring
`MysqlDbBrowser::AgenticAccess.connection!(id)` and
`Mcp::Tools::AuthorizationSupport`'s `find_job!`/`find_run!` pattern for
first-party tools. `K8sCluster::ResourceService::Unavailable`/`NotFound` and
a missing-namespace validation error are all normalized into an
`MCP::Tool::Response` with `error: true` rather than raising out of the MCP
sidecar process.

## Write-capable agentic tools

A cluster with `agentic_access_enabled` on is browsable, but read-only.
Turning on the cluster's separate `allow_writes` flag (also a checkbox on
the connection form, default `false`, independent of `agentic_access_enabled`)
additionally exposes a short, explicit allowlist of four mutating MCP tools -
not a general kubectl proxy. Expanding this allowlist is deliberately a
separate, explicitly-scoped follow-up, never an implicit consequence of
turning `allow_writes` on:

- `k8s_cluster_restart_rollout` - restarts a deployment's rollout
  (`Deployments#restart_rollout`), equivalent to `kubectl rollout restart`: a
  strategic-merge patch stamping the pod template with a
  `kubectl.kubernetes.io/restartedAt` annotation, which rolls every pod even
  though no real spec content changed. Requires `cluster_id`, `namespace`,
  `name`.
- `k8s_cluster_scale_deployment` - scales a deployment's replica count
  (`Deployments#scale`), equivalent to `kubectl scale --replicas=N`.
  Requires `cluster_id`, `namespace`, `name`, `replicas` (a non-negative
  integer - validated before any API call, raising
  `K8sCluster::ResourceService::InvalidArgument` otherwise).
- `k8s_cluster_delete_pod` - deletes a pod to force it to be rescheduled
  (`Pods#delete`), equivalent to `kubectl delete pod <name>`. A pod owned by
  a Deployment/ReplicaSet/StatefulSet/DaemonSet is recreated by its
  controller; a bare unowned pod is simply removed. Requires `cluster_id`,
  `namespace`, `name`.
- `k8s_cluster_set_node_cordon` - cordons (`cordoned: true`) or uncordons
  (`cordoned: false`) a node (`Nodes#set_cordon`), equivalent to `kubectl
  cordon`/`kubectl uncordon`: a strategic-merge patch on
  `spec.unschedulable`. Cordoning only stops new pods from being scheduled
  onto the node - it never evicts pods already running there. Requires
  `cluster_id`, `name`, `cordoned`.

Deliberately excluded, and out of scope for this allowlist entirely:
namespace deletion, any CRD/RBAC mutation, arbitrary manifest `apply`, and
`kubectl exec` into a pod - anything irreversible or with a broad blast
radius.

**Gating is a strict superset of the read gate.** Each write tool calls
`K8sCluster::AgenticAccess.cluster_with_write_access!(cluster_id)` instead of
the read tools' `.cluster!(cluster_id)`. That method first runs the same
`agentic_access_enabled` check as `.cluster!` (raising `AccessDisabled` with
the existing read-access wording if that's off), then additionally requires
`allow_writes?`, raising a distinct `K8sCluster::AgenticAccess::WriteAccessDisabled`
with its own actionable message ("An admin must enable \"Allow writes\" for
this cluster...") when read access is on but writes are not - so an agent
gets a clear, specific reason rather than a generic auth failure that reads
like the cluster isn't accessible at all.

All four write tools are registered in the same `ChatToolSet::TOOL_CLASSES` /
`WorkflowToolSet` list as the read-only tools (there is no separate write
tool set) - the per-cluster `allow_writes` check inside each tool's `#call`
is the only gate, the same "no manifest-build-time hook sees per-call
params" reasoning that applies to the read tools' per-cluster gate above.

## Audit logging

Every agentic tool call - successful or not - is logged by
`K8sCluster::AgenticAudit.log!` as a single structured line: `cluster_id`,
`tool`, `params`, and either `outcome: "success"` with the result's
serialized byte size, or `outcome: "error"` with the exception class and
message. This deliberately never logs the resolved result's actual content
(pod logs, full manifests) - only its size - so the audit trail can't become
a second, un-redacted copy of cluster data sitting in the Rails log. This is
the same spirit as the `JobLog` audit lines other MCP tool submissions leave
behind, but logged rather than persisted to a DB table: `JobLog` itself
requires a `Run`, while agentic k8s calls can equally come from a chat
session that has no Run at all.

The four write tools are the one exception to "never logs the resolved
result": each write resource-service method (`Deployments#restart_rollout`,
`Deployments#scale`, `Pods#delete`, `Nodes#set_cordon`) returns a result hash
with curated `before:`/`after:` keys - a small structured summary (a replica
count, a restart timestamp, a schedulable flag), never a full object -
and `AgenticAudit.log!` includes those two keys verbatim in the audit line
when present, so the log line itself shows the mutation's effect (e.g.
`"before":{"replicas":2},"after":{"replicas":4}`) without becoming a copy of
full pod/deployment/node manifests.

## Minimal RBAC for agentic access

The credential pasted into a cluster's kubeconfig should be scoped to the
minimum the plugin actually needs, via a dedicated ServiceAccount and
RBAC binding rather than a cluster-admin token:

**Read-only clusters** (`agentic_access_enabled` on, `allow_writes` off) only
need a `view`-equivalent `ClusterRole`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: syrus-k8s-cluster-viewer
rules:
  - apiGroups: [""]
    resources: [namespaces, pods, pods/log, services, endpoints, events, persistentvolumeclaims, nodes]
    verbs: [get, list]
  - apiGroups: [apps]
    resources: [deployments]
    verbs: [get, list]
  - apiGroups: [batch]
    resources: [cronjobs]
    verbs: [get, list]
  - apiGroups: [metrics.k8s.io]
    resources: [nodes, pods]
    verbs: [get, list]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: syrus-k8s-cluster-viewer
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: syrus-k8s-cluster-viewer
subjects:
  - kind: ServiceAccount
    name: syrus-k8s-cluster-viewer
    namespace: default
roleRef:
  kind: ClusterRole
  name: syrus-k8s-cluster-viewer
  apiGroup: rbac.authorization.k8s.io
```

**Write-enabled clusters** (`allow_writes` also on) additionally need
`patch`/`delete` scoped to exactly the resources/verbs the four write tools
use - deployment rollout restart/scale (`patch` on `deployments`), pod
deletion (`delete` on `pods`), and node cordon/uncordon (`patch` on `nodes`).
Grant this as an additional `ClusterRole` bound to the same ServiceAccount,
not by widening the read role above:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: syrus-k8s-cluster-writer
rules:
  - apiGroups: [apps]
    resources: [deployments]
    verbs: [patch]
  - apiGroups: [""]
    resources: [pods]
    verbs: [delete]
  - apiGroups: [""]
    resources: [nodes]
    verbs: [patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: syrus-k8s-cluster-writer
subjects:
  - kind: ServiceAccount
    name: syrus-k8s-cluster-viewer
    namespace: default
roleRef:
  kind: ClusterRole
  name: syrus-k8s-cluster-writer
  apiGroup: rbac.authorization.k8s.io
```

Generate the ServiceAccount's bearer token (e.g. a long-lived Secret of type
`kubernetes.io/service-account-token`, or `kubectl create token
syrus-k8s-cluster-viewer --duration=...` for a short-lived one) and paste a
kubeconfig built from it - see "Kubeconfig parsing" above. There is no
token rotation/expiry handling in v1 (a known gap - see DOC-21); an expired
token needs the operator to re-paste an updated kubeconfig.

## What's not here yet

Per DOC-21's explicit out-of-scope list: per-repository cluster association
or auto-detection of "which cluster does this repo deploy to," an in-cluster
relay agent for clusters Syrus can't reach directly (NAT/firewalled), any
general-purpose `kubectl exec` or arbitrary manifest `apply` via the agent,
cluster provisioning/teardown, and watch-API streaming (v1 uses 10s polling
for the Live tab; only worth building if that proves insufficient in
practice). Expanding the write tool allowlist itself beyond the four actions
above is also explicitly deferred to a future, separately-scoped Job rather
than an implicit consequence of this one.
