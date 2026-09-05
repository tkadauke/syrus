require "mcp"

module K8sCluster
  class ListClustersTool < MCP::Tool
    tool_name "k8s_cluster_list_clusters"

    description "List registered Kubernetes clusters with safe metadata only. " \
                "Use this first to find cluster_id values before listing/describing namespaces, " \
                "pods, deployments, services, events, PVCs, nodes, CronJobs, pod logs, or the metrics overview."

    input_schema(
      type: "object",
      properties: {}
    )

    class << self
      def call(server_context:)
        Mcp::Tools.with_database_connection do
          payload = { clusters: AgenticAccess.safe_cluster_metadata }
          MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ])
        end
      rescue StandardError => e
        Rails.logger.error("[K8sCluster::ListClustersTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
