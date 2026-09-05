require "mcp"

module K8sCluster
  # Read-only browse tools for workflow/chat agents, gated per-cluster
  # rather than globally: availability only requires the plugin to be
  # enabled and at least one KubernetesCluster to exist, since the real
  # authorization check (which specific cluster, per AgenticAccess) happens
  # inside each tool's #call once the agent names a cluster_id. Mirrors
  # MysqlDbBrowser::ChatToolSet.
  class ChatToolSet
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
      OverviewTool
    ].freeze

    def self.available_for?(_chat_session, tier:)
      K8sCluster.enabled? && %i[essential deferred].include?(tier.to_sym) && KubernetesCluster.exists?
    end

    def self.tool_definitions(tier:)
      TOOL_CLASSES.map do |klass|
        {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h
        }
      end
    end

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return MCP::Tool::Response.new([ { type: "text", text: "Unknown K8s Cluster tool: #{tool_name.inspect}" } ], error: true) unless klass

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[K8sCluster::ChatToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
