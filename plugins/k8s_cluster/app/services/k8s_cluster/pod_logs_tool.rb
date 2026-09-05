require "mcp"

module K8sCluster
  class PodLogsTool < MCP::Tool
    extend AgenticToolResponse

    DEFAULT_TAIL_LINES = 200

    tool_name "k8s_cluster_pod_logs"

    description "Get a pod's log tail on an agentic-access-enabled Kubernetes cluster. " \
                "Call k8s_cluster_list_clusters first to find an enabled cluster_id. " \
                "container is required once the pod has more than one container."

    input_schema(
      type: "object",
      required: [ "cluster_id", "name", "namespace" ],
      properties: {
        cluster_id: {
          type: "integer",
          description: "KubernetesCluster id from k8s_cluster_list_clusters."
        },
        name: {
          type: "string",
          description: "Pod name."
        },
        namespace: {
          type: "string",
          description: "Namespace containing the pod."
        },
        container: {
          type: "string",
          description: "Container name. Required when the pod has more than one container."
        },
        tail_lines: {
          type: "integer",
          minimum: 1,
          description: "Number of trailing log lines to return (default #{DEFAULT_TAIL_LINES})."
        },
        previous: {
          type: "boolean",
          description: "Return logs from the pod's previous terminated container instance."
        },
        timestamps: {
          type: "boolean",
          description: "Prefix each log line with its timestamp."
        }
      }
    )

    class << self
      def call(server_context:, cluster_id: nil, name: nil, namespace: nil, container: nil, tail_lines: nil, previous: false, timestamps: false)
        params = {
          cluster_id: cluster_id,
          name: name,
          namespace: namespace,
          container: container,
          tail_lines: tail_lines,
          previous: previous,
          timestamps: timestamps
        }

        respond_with(cluster_id: cluster_id, params: params) do
          cluster = AgenticAccess.cluster!(cluster_id)
          Pods.new(cluster).logs(
            name,
            namespace: namespace,
            container: container,
            tail_lines: tail_lines || DEFAULT_TAIL_LINES,
            previous: !!previous,
            timestamps: !!timestamps
          )
        end
      end
    end
  end
end
