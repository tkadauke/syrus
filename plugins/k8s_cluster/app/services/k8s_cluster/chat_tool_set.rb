require "mcp"

module K8sCluster
  # Browse (read-only) and write (mutating) tools for workflow/chat agents,
  # gated per-cluster rather than globally: availability only requires the
  # plugin to be enabled and at least one KubernetesCluster to exist, since
  # the real authorization check (which specific cluster, per AgenticAccess)
  # happens inside each tool's #call once the agent names a cluster_id -
  # read tools require `agentic_access_enabled`; the four write tools
  # (RestartRolloutTool, ScaleDeploymentTool, DeletePodTool,
  # SetNodeCordonTool) additionally require `allow_writes` via
  # AgenticAccess.cluster_with_write_access!. See Syrus::Plugin::GatedToolSet
  # for the shared skeleton this and MysqlDbBrowser::ChatToolSet both include.
  class ChatToolSet
    include Syrus::Plugin::GatedToolSet

    TOOL_CLASSES = [
      ListClustersTool,
      NamespacesTool,
      NodesTool,
      PodsTool,
      PodLogsTool,
      DeploymentsTool,
      ServicesTool,
      EventsTool,
      PersistentVolumeClaimsTool,
      CronJobsTool,
      OverviewTool,
      RestartRolloutTool,
      ScaleDeploymentTool,
      DeletePodTool,
      SetNodeCordonTool
    ].freeze

    gated_by K8sCluster, model: KubernetesCluster, tool_set_label: "K8s Cluster"
  end
end
