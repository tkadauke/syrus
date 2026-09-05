module K8sCluster
  extend Syrus::PluginApi

  syrus_plugin "k8s_cluster" do
    display_name "Kubernetes Cluster Viewer"
    description "Register Kubernetes/k3s clusters and browse them read-only from an admin sidebar page."
    long_description "K8s Cluster Viewer lets admins register external Kubernetes or k3s clusters, parsed from a pasted kubeconfig, with encrypted credential storage, and browse them read-only from a tabbed sidebar UI. Gated agentic access ships in later work."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/k8s_cluster.svg"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled false
    disableable true
    provides sidebar_page: "K8sCluster::SidebarPages"
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
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/services", to: "api/v1/app/admin/kubernetes_resources#services"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/endpoints", to: "api/v1/app/admin/kubernetes_resources#endpoints"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/events", to: "api/v1/app/admin/kubernetes_resources#events"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/pvcs", to: "api/v1/app/admin/kubernetes_resources#pvcs"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/nodes", to: "api/v1/app/admin/kubernetes_resources#nodes"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/cronjobs", to: "api/v1/app/admin/kubernetes_resources#cronjobs"
    route :get, "/api/v1/app/admin/kubernetes_clusters/:id/overview", to: "api/v1/app/admin/kubernetes_resources#overview"
    frontend routes: {
          "k8s_cluster/KubernetesClusters" => "app/frontend/routes/KubernetesClusters.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/k8s_cluster.json" ]
  end
end
