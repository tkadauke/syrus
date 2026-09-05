require "mcp"

module K8sCluster
  # Shared response wrapper for every read-only agentic tool: authorizes the
  # named cluster via AgenticAccess (raised inside the caller's block so the
  # same rescue below normalizes it), logs the call for audit, and normalizes
  # every K8sCluster error into an MCP::Tool::Response instead of raising out
  # of the sidecar process. `extend`ed onto each tool class so `respond_with`
  # is available as a class method alongside the MCP::Tool `call` DSL.
  module AgenticToolResponse
    class MissingNamespace < StandardError; end

    RESCUABLE_ERRORS = [
      AgenticAccess::ClusterNotFound,
      AgenticAccess::AccessDisabled,
      AgenticAccess::WriteAccessDisabled,
      ResourceService::Unavailable,
      ResourceService::NotFound,
      ResourceService::InvalidArgument,
      MissingNamespace
    ].freeze

    def respond_with(cluster_id:, params:)
      Mcp::Tools.with_database_connection do
        result = yield
        AgenticAudit.log!(cluster_id: cluster_id, tool_name: tool_name, params: params, result: result)
        MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(result) } ])
      end
    rescue *RESCUABLE_ERRORS => e
      AgenticAudit.log!(cluster_id: cluster_id, tool_name: tool_name, params: params, error: e)
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.message}" } ], error: true)
    rescue StandardError => e
      Rails.logger.error("[K8sCluster::#{tool_name}] #{e.class}: #{e.message}")
      AgenticAudit.log!(cluster_id: cluster_id, tool_name: tool_name, params: params, error: e)
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    # Cluster-scoped kinds (Namespace, Node): `name` alone selects describe
    # over list, mirroring KubernetesResourcesController#render_cluster_scoped.
    def cluster_scoped_result(service, name:)
      name.present? ? service.describe(name) : service.list
    end

    # Namespace-scoped kinds: `namespace` alone (no `name`) filters the list
    # to one namespace; omitting it lists across every namespace. Describing
    # a single object (`name` present) requires `namespace` too, mirroring
    # KubernetesResourcesController#render_namespace_scoped.
    def namespace_scoped_result(service, name:, namespace:)
      if name.present?
        raise MissingNamespace, "namespace is required to describe a specific resource" if namespace.blank?

        service.describe(name, namespace: namespace)
      else
        service.list(namespace: namespace)
      end
    end
  end
end
