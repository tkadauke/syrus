module K8sCluster::Cli
  class Services < Base
    def call(args:, flags:, user:)
      authorize!(user)
      payload = service(K8sCluster::Services, cluster_for(flags["cluster"]), user).list(namespace: flags["namespace"])
      rows = Array(payload[:services]).map { |item| [ item[:name], item[:namespace], item[:type], value_or_dash(item[:cluster_ip]), format_ports(item[:ports]) ] }
      self.class.table(columns: [ "NAME", "NAMESPACE", "TYPE", "CLUSTER-IP", "PORTS" ], rows: rows)
    end

    private

    def format_ports(ports) = Array(ports).map { |port| "#{port[:port]}/#{value_or_dash(port[:protocol])}" }.join(",").presence || "-"
  end
end
