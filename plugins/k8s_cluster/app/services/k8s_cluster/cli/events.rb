module K8sCluster::Cli
  class Events < Base
    def call(args:, flags:, user:)
      authorize!(user)
      payload = service(K8sCluster::Events, cluster_for(flags["cluster"]), user).list(namespace: flags["namespace"])
      rows = Array(payload[:events]).map do |item|
        involved = item[:involved_object] || {}
        object = "#{involved[:kind]}/#{involved[:name]}".sub(%r{\A/\z}, "")
        [ item[:namespace], item[:type], item[:reason], value_or_dash(object), item[:message] ]
      end
      self.class.table(columns: [ "NAMESPACE", "TYPE", "REASON", "OBJECT", "MESSAGE" ], rows: rows)
    end
  end
end
