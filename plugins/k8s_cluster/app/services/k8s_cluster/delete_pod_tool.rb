require "mcp"

module K8sCluster
  # Write tool (EPIC-306 phase 2): deletes a pod to force a reschedule.
  # Gated by `agentic_access_enabled? && allow_writes?`, see RestartRolloutTool.
  class DeletePodTool < MCP::Tool
    extend AgenticToolResponse

    tool_name "k8s_cluster_delete_pod"

    description "Delete a pod to force it to be rescheduled (equivalent to `kubectl delete pod <name>`) on a " \
                "Kubernetes cluster with write access enabled. A pod owned by a Deployment/ReplicaSet/StatefulSet/ " \
                "DaemonSet is recreated by its controller; a bare unowned pod is simply removed. Requires both " \
                "agentic_access_enabled and allow_writes on the cluster. Call k8s_cluster_list_clusters first to " \
                "find an enabled cluster_id."

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
          description: "Namespace the pod lives in."
        },
        name: {
          type: "string",
          description: "Pod name to delete."
        }
      }
    )

    class << self
      def call(server_context:, cluster_id: nil, namespace: nil, name: nil)
        params = { cluster_id: cluster_id, namespace: namespace, name: name }
        respond_with(cluster_id: cluster_id, params: params) do
          cluster = AgenticAccess.cluster_with_write_access!(cluster_id)
          Pods.new(cluster).delete(name, namespace: namespace)
        end
      end
    end
  end
end
