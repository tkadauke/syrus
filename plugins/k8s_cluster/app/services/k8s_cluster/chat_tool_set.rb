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
  # AgenticAccess.cluster_with_write_access!. The TOOL_CLASSES/dispatch
  # skeleton itself is shared with MysqlDbBrowser::ChatToolSet via
  # Syrus::Plugin::GatedToolSet.
  class ChatToolSet
    include Syrus::Plugin::GatedToolSet

    gated_by plugin: K8sCluster, model: KubernetesCluster, label: "K8s Cluster"

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

    def self.available_for?(_chat_session, tier:)
      %i[essential deferred].include?(tier.to_sym) && gated?
    end
  end
end
