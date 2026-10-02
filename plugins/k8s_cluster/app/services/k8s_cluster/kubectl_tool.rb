require "mcp"

module K8sCluster
  class KubectlTool < MCP::Tool
    tool_name Kubectl::TOOL_NAME

    description "Run kubectl using a credential_store-backed k8s_cluster.kubeconfig credential. " \
                "The kubeconfig is materialized only as a temporary 0600 file passed through KUBECONFIG; " \
                "credential access is audited and stdout/stderr are redacted. Pass context and namespace as " \
                "separate arguments rather than embedding those flags in kubectl args."

    input_schema(
      type: "object",
      required: [ "credential", "args" ],
      properties: {
        credential: {
          type: [ "integer", "string" ],
          description: "Credential id or unique name for a k8s_cluster.kubeconfig credential."
        },
        args: {
          type: "array",
          items: { type: "string" },
          minItems: 1,
          description: "kubectl arguments without the kubectl executable, kubeconfig, context, or namespace flags."
        },
        kube_context: {
          type: "string",
          description: "Optional kubeconfig context to use. Validated against credential metadata and allowed_kube_contexts constraints."
        },
        cluster: {
          type: "string",
          description: "Optional cluster label for validation against credential metadata and allowed_kube_clusters constraints. This is not passed as a kubectl flag."
        },
        namespace: {
          type: "string",
          description: "Optional namespace to pass to kubectl and validate against allowed_kube_namespaces constraints."
        },
        allow_risky_command: {
          type: "boolean",
          description: "Explicitly allow mutating kubectl commands such as apply, delete, exec, cp, patch, rollout, scale, or drain. Chat-surface calls cannot use this self-authorization flag."
        },
        allow_secret_output: {
          type: "boolean",
          description: "Explicitly allow commands likely to print Secret values, such as get secrets -o yaml or describe secret. Chat-surface calls cannot use this self-authorization flag."
        }
      }
    )

    class << self
      def call(server_context:, credential: nil, args: nil, kube_context: nil, cluster: nil, namespace: nil, allow_risky_command: false, allow_secret_output: false)
        context = McpToolContext.from_server_context(server_context)
        payload = Kubectl.call(
          context: context,
          credential: credential,
          args: args,
          kube_context: kube_context,
          cluster: cluster,
          namespace: namespace,
          allow_risky_command: allow_risky_command,
          allow_secret_output: allow_secret_output
        )
        MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ], error: !payload.fetch(:ok))
      rescue CredentialStore::Broker::Error, Kubectl::Error => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
