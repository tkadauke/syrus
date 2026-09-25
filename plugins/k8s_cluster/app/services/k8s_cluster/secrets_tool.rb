require "mcp"

module K8sCluster
  # Secret browsing redacted server-side: list and describe return
  # metadata only (name, namespace, type, key names, created_at) - secret
  # data values never leave the Kubernetes API server in any payload,
  # log, or tool response built from K8sCluster::Secrets.
  class SecretsTool < MCP::Tool
    extend AgenticToolResponse

    tool_name "k8s_cluster_secrets"

    description "List or describe Secrets (metadata only - values are never returned) on an agentic-access-enabled Kubernetes cluster. " \
                "Call k8s_cluster_list_clusters first to find an enabled cluster_id. " \
                "Omit namespace to list across all namespaces; pass name and namespace together to describe a single Secret."

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
          description: "Restrict to one namespace. Omit to list Secrets across all namespaces."
        },
        name: {
          type: "string",
          description: "Secret name to describe. Requires namespace."
        }
      }
    )

    class << self
      def call(server_context:, cluster_id: nil, namespace: nil, name: nil)
        params = { cluster_id: cluster_id, namespace: namespace, name: name }
        respond_with(cluster_id: cluster_id, params: params) do
          cluster = AgenticAccess.cluster!(cluster_id)
          namespace_scoped_result(Secrets.new(cluster), name: name, namespace: namespace)
        end
      end
    end
  end
end
