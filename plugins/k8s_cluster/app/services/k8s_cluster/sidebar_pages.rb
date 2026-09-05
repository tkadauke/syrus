module K8sCluster
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      return [] unless K8sCluster.enabled?
      return [] unless Current.user&.admin?

      [
        {
          id: "k8s_cluster.clusters",
          label: "K8s Clusters",
          label_key: "k8s_cluster:nav_k8s_clusters",
          path: "/k8s_clusters",
          paths: [ "/k8s_clusters" ],
          component: "k8s_cluster/KubernetesClusters",
          icon: "server",
          order: 71
        }
      ]
    end
  end
end
