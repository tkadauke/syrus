require "mcp"

module CredentialStore
  class ListCredentialsTool < MCP::Tool
    tool_name "credential_store_list_credentials"

    description "List active, non-expired credentials visible in this agent context using non-secret metadata only. " \
                "Discovery does not grant use: actual access still requires broker authorization, permissions, leases, " \
                "target constraints, and audit logging at execution time."

    input_schema(
      properties: {
        credential_type: { type: "string", description: "Optional exact credential type filter." },
        scope: { type: "string", enum: Credential::ALLOWED_SCOPES, description: "Optional scope filter." },
        query: { type: "string", description: "Optional case-insensitive name or description query." },
        limit: { type: "integer", minimum: 1, maximum: CredentialDiscovery::MAX_LIMIT, description: "Maximum results, default 20 and maximum 50." }
      }
    )

    class << self
      def capability_descriptor_value
        PermissionProvider.capability_descriptor("credential.metadata/list@v1")
      end
    end

    class << self
      def call(server_context:, credential_type: nil, scope: nil, query: nil, limit: CredentialDiscovery::DEFAULT_LIMIT)
        context = McpToolContext.from_server_context(server_context)
        payload = CredentialDiscovery.call(
          context: context,
          credential_type: credential_type,
          scope: scope,
          query: query,
          limit: limit
        )
        MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ])
      rescue CredentialDiscovery::InvalidFilter => e
        Mcp::Tools.invalid(e.message)
      rescue StandardError => e
        Rails.logger.error("[CredentialStore::ListCredentialsTool] #{e.class}")
        Mcp::Tools.invalid("Could not list stored credential metadata")
      end
    end
  end
end
