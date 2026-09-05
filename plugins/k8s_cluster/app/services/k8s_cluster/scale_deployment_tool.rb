require "mcp"

module K8sCluster
  # Write tool (EPIC-306 phase 2): scales a deployment's replica count.
  # Gated by `agentic_access_enabled? && allow_writes?`, see RestartRolloutTool.
  class ScaleDeploymentTool < MCP::Tool
    extend AgenticToolResponse

    tool_name "k8s_cluster_scale_deployment"

    description "Scale a deployment's replica count (equivalent to `kubectl scale deployment/<name> --replicas=N`) " \
                "on a Kubernetes cluster with write access enabled. Requires both agentic_access_enabled and " \
                "allow_writes on the cluster. Call k8s_cluster_list_clusters first to find an enabled cluster_id."

    input_schema(
      type: "object",
      required: [ "cluster_id", "namespace", "name", "replicas" ],
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
          description: "Deployment name to scale."
        },
        replicas: {
          type: "integer",
          minimum: 0,
          description: "Target replica count."
        }
      }
    )

    class << self
      def call(server_context:, cluster_id: nil, namespace: nil, name: nil, replicas: nil)
        params = { cluster_id: cluster_id, namespace: namespace, name: name, replicas: replicas }
        respond_with(cluster_id: cluster_id, params: params) do
          cluster = AgenticAccess.cluster_with_write_access!(cluster_id)
          Deployments.new(cluster).scale(name, namespace: namespace, replicas: replicas)
        end
      end
    end
  end
end
