module K8sCluster
  class WorkflowToolSet
    include Syrus::Plugin::McpToolSet
    include Syrus::Plugin::GatedToolSet

    gated_by plugin: K8sCluster, model: KubernetesCluster, delegate_to: ChatToolSet
  end
end
