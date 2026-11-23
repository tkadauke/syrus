module K8sCluster
  extend Syrus::PluginApi

  syrus_plugin "k8s_cluster" do
    requires_syrus nil
    experimental true
    display_name "Kubernetes Cluster Viewer"
    description "Register Kubernetes/k3s clusters and browse them read-only from an admin sidebar page."
    long_description "K8s Cluster Viewer lets admins register external Kubernetes or k3s clusters, parsed from a pasted kubeconfig, with encrypted credential storage, and browse them read-only from a tabbed sidebar UI. Read-only cluster inspection is also available to the Syrus agent as MCP tools, gated per-cluster via agentic_access_enabled."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/k8s_cluster.svg"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled false
    disableable true
    depends_on [ "credential_store" ]
    credential_types [
      { name: "k8s_cluster.kubeconfig", label: "Kubernetes kubeconfig", description: "Kubeconfig material for a Kubernetes cluster." },
      { name: "k8s_cluster.service_account", label: "Kubernetes service account", description: "Service account token or config for Kubernetes access." }
    ]
    cli_commands [
      { path: %w[k8s clusters], summary: "List registered Kubernetes clusters", handler: "K8sCluster::Cli::Clusters" },
      { path: %w[k8s namespaces], summary: "List namespaces in a cluster", handler: "K8sCluster::Cli::Namespaces", flags: [ { name: "cluster" } ] },
      { path: %w[k8s pods], summary: "List pods", handler: "K8sCluster::Cli::Pods", flags: [ { name: "cluster" }, { name: "namespace" } ] },
      { path: %w[k8s deployments], summary: "List deployments", handler: "K8sCluster::Cli::Deployments", flags: [ { name: "cluster" }, { name: "namespace" } ] },
      { path: %w[k8s services], summary: "List services", handler: "K8sCluster::Cli::Services", flags: [ { name: "cluster" }, { name: "namespace" } ] },
      { path: %w[k8s nodes], summary: "List cluster nodes", handler: "K8sCluster::Cli::Nodes", flags: [ { name: "cluster" } ] },
      { path: %w[k8s pvcs], summary: "List persistent volume claims", handler: "K8sCluster::Cli::PersistentVolumeClaims", flags: [ { name: "cluster" }, { name: "namespace" } ] },
      { path: %w[k8s events], summary: "List recent cluster events", handler: "K8sCluster::Cli::Events", flags: [ { name: "cluster" }, { name: "namespace" } ] },
      { path: %w[k8s logs], summary: "Show a pod's log tail", handler: "K8sCluster::Cli::Logs", arguments: [ { name: "pod", required: true } ], flags: [ { name: "cluster" }, { name: "namespace", required: true }, { name: "container" }, { name: "tail", type: :integer, default: 200 } ] },
      { path: %w[k8s overview], summary: "Show aggregate node/pod CPU and memory usage", handler: "K8sCluster::Cli::Overview", flags: [ { name: "cluster" } ] }
    ]
    provides sidebar_page: "K8sCluster::SidebarPages",
             mcp_tool_set: "K8sCluster::WorkflowToolSet",
             chat_mcp_tool_set: "K8sCluster::ChatToolSet",
             permission_provider: "K8sCluster::PermissionProvider",
             callbacks: "K8sCluster::Callbacks"
    tick_interval 5.minutes
    route :get, "/api/v1/app/admin/kubernetes_clusters", to: "api/v1/app/admin/kubernetes_clusters#index"
    route :post, "/api/v1/app/admin/kubernetes_clusters", to: "api/v1/app/admin/kubernetes_clusters#create"
    route :patch, "/api/v1/app/admin/kubernetes_clusters/:id", to: "api/v1/app/admin/kubernetes_clusters#update"
    route :delete, "/api/v1/app/admin/kubernetes_clusters/:id", to: "api/v1/app/admin/kubernetes_clusters#destroy"
    route :post, "/api/v1/app/admin/kubernetes_clusters/test", to: "api/v1/app/admin/kubernetes_clusters#test_connection"
    route :post, "/api/v1/app/admin/kubernetes_clusters/:id/test", to: "api/v1/app/admin/kubernetes_clusters#test_connection"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/namespaces", to: "api/v1/app/admin/kubernetes_resources#namespaces"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/pods", to: "api/v1/app/admin/kubernetes_resources#pods"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/pods/:name/logs", to: "api/v1/app/admin/kubernetes_resources#pod_logs"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/deployments", to: "api/v1/app/admin/kubernetes_resources#deployments"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/statefulsets", to: "api/v1/app/admin/kubernetes_resources#statefulsets"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/daemonsets", to: "api/v1/app/admin/kubernetes_resources#daemonsets"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/jobs", to: "api/v1/app/admin/kubernetes_resources#jobs"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/services", to: "api/v1/app/admin/kubernetes_resources#services"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/ingresses", to: "api/v1/app/admin/kubernetes_resources#ingresses"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/endpoints", to: "api/v1/app/admin/kubernetes_resources#endpoints"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/events", to: "api/v1/app/admin/kubernetes_resources#events"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/pvcs", to: "api/v1/app/admin/kubernetes_resources#pvcs"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/nodes", to: "api/v1/app/admin/kubernetes_resources#nodes"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/cronjobs", to: "api/v1/app/admin/kubernetes_resources#cronjobs"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/configmaps", to: "api/v1/app/admin/kubernetes_resources#configmaps"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/secrets", to: "api/v1/app/admin/kubernetes_resources#secrets"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/overview", to: "api/v1/app/admin/kubernetes_resources#overview"
    frontend routes: {
          "k8s_cluster/KubernetesClusters" => "app/frontend/routes/KubernetesClusters.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/k8s_cluster.json" ]
  end
end
