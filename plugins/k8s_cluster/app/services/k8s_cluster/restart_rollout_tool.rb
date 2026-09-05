require "mcp"

module K8sCluster
  # Write tool (EPIC-306 phase 2): restarts a deployment's rollout, gated by
  # `agentic_access_enabled? && allow_writes?` via AgenticAccess.cluster_with_write_access!,
  # a strictly narrower gate than the read-only tools' `AgenticAccess.cluster!`.
  class RestartRolloutTool < MCP::Tool
    extend AgenticToolResponse

    tool_name "k8s_cluster_restart_rollout"

    description "Restart a deployment's rollout (equivalent to `kubectl rollout restart`) on a Kubernetes cluster " \
                "with write access enabled. Requires both agentic_access_enabled and allow_writes on the cluster. " \
                "Call k8s_cluster_list_clusters first to find an enabled cluster_id."

    input_schema(
      type: "object",
      required: [ "cluster_id", "namespace", "name" ],
      properties: {
        cluster_id: {
          type: "integer",
          description: "KubernetesCluster id from k8s_cluster_list_clusters."
        },
        namespace: {
          type: "string",
          description: "Namespace the deployment lives in."
        },
        name: {
          type: "string",
          description: "Deployment name to restart."
        }
      }
    )

    class << self
      def call(server_context:, cluster_id: nil, namespace: nil, name: nil)
        params = { cluster_id: cluster_id, namespace: namespace, name: name }
        respond_with(cluster_id: cluster_id, params: params) do
          cluster = AgenticAccess.cluster_with_write_access!(cluster_id)
          Deployments.new(cluster).restart_rollout(name, namespace: namespace)
        end
      end
    end
  end
end
