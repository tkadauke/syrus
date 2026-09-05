require "mcp"

module K8sCluster
  class PodsTool < MCP::Tool
    extend AgenticToolResponse

    tool_name "k8s_cluster_pods"

    description "List or describe pods on an agentic-access-enabled Kubernetes cluster. " \
                "Call k8s_cluster_list_clusters first to find an enabled cluster_id. " \
                "Omit namespace to list across all namespaces; pass name and namespace together to describe a single pod."

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
          description: "Restrict to one namespace. Omit to list pods across all namespaces."
        },
        name: {
          type: "string",
          description: "Pod name to describe. Requires namespace."
        }
      }
    )

    class << self
      def call(server_context:, cluster_id: nil, namespace: nil, name: nil)
        params = { cluster_id: cluster_id, namespace: namespace, name: name }
        respond_with(cluster_id: cluster_id, params: params) do
          cluster = AgenticAccess.cluster!(cluster_id)
          namespace_scoped_result(Pods.new(cluster), name: name, namespace: namespace)
        end
      end
    end
  end
end
