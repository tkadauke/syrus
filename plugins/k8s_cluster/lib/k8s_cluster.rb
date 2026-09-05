module K8sCluster
  extend Syrus::PluginApi

  syrus_plugin "k8s_cluster" do
    display_name "Kubernetes Cluster Viewer"
    description "Register Kubernetes/k3s clusters and browse them read-only from an admin sidebar page."
    long_description "K8s Cluster Viewer lets admins register external Kubernetes or k3s clusters, parsed from a pasted kubeconfig, with encrypted credential storage. This scaffold covers connection management only; cluster-resource browsing and agentic access ship in later work."
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
    frontend routes: {
          "k8s_cluster/KubernetesClusters" => "app/frontend/routes/KubernetesClusters.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/k8s_cluster.json" ]
  end
end
