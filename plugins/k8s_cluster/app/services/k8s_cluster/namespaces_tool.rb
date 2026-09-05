require "mcp"

module K8sCluster
  class NamespacesTool < MCP::Tool
    extend AgenticToolResponse

    tool_name "k8s_cluster_namespaces"

    description "List or describe namespaces on an agentic-access-enabled Kubernetes cluster. " \
                "Call k8s_cluster_list_clusters first to find an enabled cluster_id. " \
                "Omit name to list every namespace; pass name to describe a single one."

    input_schema(
      type: "object",
      required: [ "cluster_id" ],
      properties: {
        cluster_id: {
          type: "integer",
          description: "KubernetesCluster id from k8s_cluster_list_clusters."
        },
        name: {
          type: "string",
          description: "Namespace name to describe. Omit to list all namespaces."
        }
      }
    )

    class << self
      def call(server_context:, cluster_id: nil, name: nil)
        params = { cluster_id: cluster_id, name: name }
        respond_with(cluster_id: cluster_id, params: params) do
          cluster = AgenticAccess.cluster!(cluster_id)
          cluster_scoped_result(Namespaces.new(cluster), name: name)
        end
      end
    end
  end
end
