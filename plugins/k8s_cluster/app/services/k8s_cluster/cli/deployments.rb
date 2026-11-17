module K8sCluster::Cli
  class Deployments < Base
    def call(args:, flags:, user:)
      authorize!(user)
      payload = service(K8sCluster::Deployments, cluster_for(flags["cluster"]), user).list(namespace: flags["namespace"])
      self.class.table(columns: [ "NAME", "NAMESPACE", "REPLICAS", "READY", "AVAILABLE", "UPDATED" ], rows: Array(payload[:deployments]).map { |item| [ item[:name], item[:namespace], item[:replicas], item[:ready_replicas], item[:available_replicas], item[:updated_replicas] ] })
    end
  end
end
