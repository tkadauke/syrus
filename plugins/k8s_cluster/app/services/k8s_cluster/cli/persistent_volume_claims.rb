module K8sCluster::Cli
  class PersistentVolumeClaims < Base
    def call(args:, flags:, user:)
      authorize!(user)
      payload = service(K8sCluster::PersistentVolumeClaims, cluster_for(flags["cluster"]), user).list(namespace: flags["namespace"])
      rows = Array(payload[:persistent_volume_claims]).map { |item| [ item[:name], item[:namespace], item[:status], value_or_dash(item[:capacity]), value_or_dash(item[:storage_class]) ] }
      self.class.table(columns: [ "NAME", "NAMESPACE", "STATUS", "CAPACITY", "STORAGE CLASS" ], rows: rows)
    end
  end
end
