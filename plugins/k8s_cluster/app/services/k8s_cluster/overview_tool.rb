require "mcp"

module K8sCluster
  class OverviewTool < MCP::Tool
    extend AgenticToolResponse

    tool_name "k8s_cluster_overview"

    description "Get an aggregate CPU/memory metrics overview (nodes and pods) for an " \
                "agentic-access-enabled Kubernetes cluster, via the metrics.k8s.io API. " \
                "Call k8s_cluster_list_clusters first to find an enabled cluster_id. " \
                "Soft-fails per-section with available: false when metrics-server isn't installed."

    input_schema(
      type: "object",
      required: [ "cluster_id" ],
      properties: {
        cluster_id: {
          type: "integer",
          description: "KubernetesCluster id from k8s_cluster_list_clusters."
        }
      }
    )

    class << self
      def call(server_context:, cluster_id: nil)
        params = { cluster_id: cluster_id }
        respond_with(cluster_id: cluster_id, params: params) do
          cluster = AgenticAccess.cluster!(cluster_id)
          Overview.new(cluster).call
        end
      end
    end
  end
end
