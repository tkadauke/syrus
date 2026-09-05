module K8sCluster
  # Per-cluster authorization for agent-issued (workflow/chat MCP tool)
  # access, mirroring MysqlDbBrowser::AgenticAccess. Every agentic tool call
  # names a KubernetesCluster id in its params, and this is the single place
  # that resolves it and enforces that cluster's own `agentic_access_enabled`
  # flag before any tool touches the external Kubernetes API server. There is
  # no framework hook to do this at manifest-build time (ChatToolSet/
  # WorkflowToolSet#available_for? only ever sees the surface, never an
  # individual call's params) - so each tool calls this from inside its own
  # #call, mirroring Mcp::Tools::AuthorizationSupport's find_*! pattern for
  # first-party tools.
  class AgenticAccess
    class ClusterNotFound < StandardError; end
    class AccessDisabled < StandardError; end
    class WriteAccessDisabled < StandardError; end

    SAFE_METADATA_FIELDS = %i[
      id
      label
      agentic_access_enabled
      allow_writes
      created_at
      updated_at
    ].freeze

    def self.safe_cluster_metadata
      KubernetesCluster.order(:label, :id).map do |cluster|
        {
          id: cluster.id,
          label: cluster.label,
          agentic_access_enabled: cluster.agentic_access_enabled,
          allow_writes: cluster.allow_writes,
          created_at: cluster.created_at.iso8601,
          updated_at: cluster.updated_at.iso8601
        }.slice(*SAFE_METADATA_FIELDS)
      end
    end

    def self.cluster!(id)
      cluster = KubernetesCluster.find_by(id: id)
      raise ClusterNotFound, "Kubernetes cluster #{id.inspect} was not found." unless cluster
      unless cluster.agentic_access_enabled?
        raise AccessDisabled, "Agentic access is disabled for the \"#{cluster.label}\" cluster. " \
          "An admin must enable it from K8s Cluster connection settings before agents can query it."
      end

      cluster
    end

    # Second, stricter gate for the write/mutating tools (EPIC-306 phase 2):
    # requires both agentic_access_enabled (via .cluster!) and the cluster's
    # own, independent allow_writes opt-in. Raises a distinct error so an
    # agent that finds a read-enabled-but-write-disabled cluster gets an
    # actionable "turn on allow_writes" message instead of the generic
    # AccessDisabled wording, which talks about read access.
    def self.cluster_with_write_access!(id)
      cluster = cluster!(id)
      unless cluster.allow_writes?
        raise WriteAccessDisabled, "Write access is disabled for the \"#{cluster.label}\" cluster. " \
          "An admin must enable \"Allow writes\" for this cluster from K8s Cluster connection settings " \
          "before agents can run mutating actions against it."
      end

      cluster
    end
  end
end
