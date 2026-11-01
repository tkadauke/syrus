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
      StatefulSetsTool,
      DaemonSetsTool,
      JobsTool,
      ServicesTool,
      IngressesTool,
      ConfigMapsTool,
      SecretsTool,
      EventsTool,
      PersistentVolumeClaimsTool,
      CronJobsTool,
      OverviewTool,
      RestartRolloutTool,
      ScaleDeploymentTool,
      DeletePodTool,
      SetNodeCordonTool,
      KubectlTool
    ].freeze

    COWORKER_READ_TOOLS = [
      ListClustersTool,
      NamespacesTool,
      NodesTool,
      PodsTool,
      PodLogsTool,
      DeploymentsTool,
      StatefulSetsTool,
      DaemonSetsTool,
      JobsTool,
      CronJobsTool,
      ServicesTool,
      IngressesTool,
      PersistentVolumeClaimsTool,
      EventsTool,
      ConfigMapsTool,
      OverviewTool
    ].freeze

    coworker_grant(
      name: "k8s.read",
      label: "Read Kubernetes clusters",
      description: "Browse selected agentic-access Kubernetes clusters with read-only, redacted tools.",
      tools: COWORKER_READ_TOOLS,
      default_policy: "confirm",
      max_policy: "auto",
      scope: {
        options: lambda { |user:|
          context = McpToolContext.new(surface: :chat, role: AgentRole::CHAT_PLANNER, user: user)
          AgenticAccess.safe_cluster_metadata(context: context).pluck(:id)
        },
        label: ->(id) { KubernetesCluster.find_by(id: id)&.label || "Kubernetes cluster #{id}" },
        valid: lambda { |id, user:|
          context = McpToolContext.new(surface: :chat, role: AgentRole::CHAT_PLANNER, user: user)
          AgenticAccess.safe_cluster_metadata(context: context).any? { |cluster| cluster.fetch(:id).to_s == id.to_s }
        }
      }
    )

    def self.available_for?(_chat_session, tier:)
      %i[essential deferred].include?(tier.to_sym) && (gated? || credential_backed_tool_available?)
    end

    def self.credential_backed_tool_available?
      K8sCluster.enabled? && defined?(CredentialStore) && CredentialStore.enabled?
    end

    DESCRIPTORS = {
      "k8s_cluster_list_clusters" => "k8s.cluster/list@v1",
      "k8s_cluster_namespaces" => "k8s.namespace/read@v1",
      "k8s_cluster_nodes" => "k8s.node/read@v1",
      "k8s_cluster_pods" => "k8s.pod/read@v1",
      "k8s_cluster_pod_logs" => "k8s.pod_logs/read@v1",
      "k8s_cluster_deployments" => "k8s.deployment/read@v1",
      "k8s_cluster_statefulsets" => "k8s.statefulset/read@v1",
      "k8s_cluster_daemonsets" => "k8s.daemonset/read@v1",
      "k8s_cluster_jobs" => "k8s.job/read@v1",
      "k8s_cluster_services" => "k8s.service/read@v1",
      "k8s_cluster_ingresses" => "k8s.ingress/read@v1",
      "k8s_cluster_configmaps" => "k8s.configmap/read@v1",
      "k8s_cluster_secrets" => "k8s.secret/read@v1",
      "k8s_cluster_events" => "k8s.event/read@v1",
      "k8s_cluster_pvcs" => "k8s.persistent_volume_claim/read@v1",
      "k8s_cluster_cronjobs" => "k8s.cronjob/read@v1",
      "k8s_cluster_overview" => "k8s.metrics/read@v1",
      "k8s_cluster_restart_rollout" => "k8s.deployment/restart@v1",
      "k8s_cluster_scale_deployment" => "k8s.deployment/scale@v1",
      "k8s_cluster_delete_pod" => "k8s.pod/delete@v1",
      "k8s_cluster_set_node_cordon" => "k8s.node/cordon@v1",
      "k8s_cluster_kubectl" => "k8s.raw/execute@v1"
    }.freeze

    def self.tool_definitions(tier: nil, context: nil)
      super.map do |definition|
        operation = DESCRIPTORS.fetch(definition.fetch(:name))
        definition.merge(capability_descriptor: PermissionProvider.capability_descriptor(operation))
      end
    end
  end
end
