module K8sCluster
  class WorkflowToolSet
    include Syrus::Host::McpToolSet
    include Syrus::Host::GatedToolSet

    gated_by plugin: K8sCluster, model: Syrus::Host::KubernetesCluster, delegate_to: ChatToolSet

    def self.available_for?(repository)
      repository.present? && (gated? || ChatToolSet.credential_backed_tool_available?)
    end
  end
end
