require "mcp"

module K8sCluster
  # Write tool (EPIC-306 phase 2): cordons or uncordons a node.
  # Gated by `agentic_access_enabled? && allow_writes?`, see RestartRolloutTool.
  class SetNodeCordonTool < MCP::Tool
    extend AgenticToolResponse

    tool_name "k8s_cluster_set_node_cordon"

    description "Cordon (cordoned: true) or uncordon (cordoned: false) a node - equivalent to `kubectl cordon`/" \
                "`kubectl uncordon <node>` - on a Kubernetes cluster with write access enabled. Cordoning stops " \
                "new pods from being scheduled onto the node; it does not evict pods already running there. " \
                "Requires both agentic_access_enabled and allow_writes on the cluster. Call " \
                "k8s_cluster_list_clusters first to find an enabled cluster_id."

    input_schema(
      type: "object",
      required: [ "cluster_id", "name", "cordoned" ],
      properties: {
        cluster_id: {
          type: "integer",
          description: "KubernetesCluster id from k8s_cluster_list_clusters."
        },
        name: {
          type: "string",
          description: "Node name to cordon or uncordon."
        },
        cordoned: {
          type: "boolean",
          description: "true to cordon (mark unschedulable), false to uncordon."
        }
      }
    )

    class << self
      def call(server_context:, cluster_id: nil, name: nil, cordoned: nil)
        params = { cluster_id: cluster_id, name: name, cordoned: cordoned }
        respond_with(cluster_id: cluster_id, params: params) do
          cluster = AgenticAccess.cluster_with_write_access!(cluster_id)
          Nodes.new(cluster).set_cordon(name, cordoned: cordoned)
        end
      end
    end
  end
end
