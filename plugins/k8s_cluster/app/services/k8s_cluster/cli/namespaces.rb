module K8sCluster::Cli
  class Namespaces < Base
    def call(args:, flags:, user:)
      authorize!(user)
      payload = service(K8sCluster::Namespaces, cluster_for(flags["cluster"]), user).list
      self.class.table(columns: [ "NAME", "STATUS" ], rows: Array(payload[:namespaces]).map { |item| [ item[:name], value_or_dash(item[:status]) ] })
    end
  end
end
