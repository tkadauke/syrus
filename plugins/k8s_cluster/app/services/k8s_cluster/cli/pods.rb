module K8sCluster::Cli
  class Pods < Base
    def call(args:, flags:, user:)
      authorize!(user)
      payload = service(K8sCluster::Pods, cluster_for(flags["cluster"]), user).list(namespace: flags["namespace"])
      self.class.table(columns: [ "NAME", "NAMESPACE", "STATUS", "READY", "RESTARTS", "NODE" ], rows: Array(payload[:pods]).map { |item| [ item[:name], item[:namespace], item[:status], item[:ready], item[:restart_count], value_or_dash(item[:node_name]) ] })
    end
  end
end
