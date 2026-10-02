module K8sCluster
  class WorkflowToolSet
    include Syrus::Plugin::McpToolSet
    include Syrus::Plugin::GatedToolSet

    gated_by plugin: K8sCluster, model: KubernetesCluster, delegate_to: ChatToolSet

    def self.available_for?(repository)
      repository.present? && (gated? || ChatToolSet.credential_backed_tool_available?)
    end
  end
end
