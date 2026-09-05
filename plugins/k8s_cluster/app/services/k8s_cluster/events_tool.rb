require "mcp"

module K8sCluster
  # List-only: an individual Event has no useful "describe" beyond what the
  # list row already shows (mirrors K8sCluster::Events itself).
  class EventsTool < MCP::Tool
    extend AgenticToolResponse

    tool_name "k8s_cluster_events"

    description "List events on an agentic-access-enabled Kubernetes cluster, most-recent-first. " \
                "Call k8s_cluster_list_clusters first to find an enabled cluster_id. " \
                "Omit namespace to list across all namespaces."

    input_schema(
      type: "object",
      required: [ "cluster_id" ],
      properties: {
        cluster_id: {
          type: "integer",
          description: "KubernetesCluster id from k8s_cluster_list_clusters."
        },
        namespace: {
          type: "string",
          description: "Restrict to one namespace. Omit to list events across all namespaces."
        }
      }
    )

    class << self
      def call(server_context:, cluster_id: nil, namespace: nil)
        params = { cluster_id: cluster_id, namespace: namespace }
        respond_with(cluster_id: cluster_id, params: params) do
          cluster = AgenticAccess.cluster!(cluster_id)
          Events.new(cluster).list(namespace: namespace)
        end
      end
    end
  end
end
