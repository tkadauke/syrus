module K8sCluster
  class WorkflowToolSet
    include Syrus::Plugin::GatedToolSet::Workflow

    gated_by K8sCluster, model: KubernetesCluster, chat_tool_set: ChatToolSet
  end
end
