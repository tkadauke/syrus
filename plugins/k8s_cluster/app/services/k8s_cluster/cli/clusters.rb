module K8sCluster::Cli
  class Clusters < Base
    def call(args:, flags:, user:)
      authorize!(user)
      rows = KubernetesCluster.order(:label).map { |cluster| [ cluster.id, cluster.label, cluster.api_server_url, yes_no(cluster.agentic_access_enabled), yes_no(cluster.allow_writes) ] }
      self.class.table(columns: [ "ID", "LABEL", "API SERVER", "AGENTIC", "WRITES" ], rows: rows)
    end
  end
end
