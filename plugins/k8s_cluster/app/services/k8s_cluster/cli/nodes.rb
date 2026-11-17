module K8sCluster::Cli
  class Nodes < Base
    def call(args:, flags:, user:)
      authorize!(user)
      payload = service(K8sCluster::Nodes, cluster_for(flags["cluster"]), user).list
      rows = Array(payload[:nodes]).map { |item| [ item[:name], yes_no(item[:ready]), Array(item[:roles]).join(","), value_or_dash(item[:kubelet_version]), value_or_dash(item[:internal_ip]) ] }
      self.class.table(columns: [ "NAME", "READY", "ROLES", "VERSION", "INTERNAL-IP" ], rows: rows)
    end
  end
end
