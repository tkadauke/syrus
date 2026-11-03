require "mcp"

module Mcp::Tools
  class RequestPermissionTool < MCP::Tool
    tool_name "request_permission"
    description "Ask the owner for authority for yourself. Creating a request grants nothing: the owner sees the " \
      "same permission card as for a blocked tool call and decides. You can only ever request for yourself. " \
      "Name the exact capability and operation (see discover_coworker_capabilities), the narrowest resource scope " \
      "and constraints you need, why you need it, and the shortest duration that suffices. Equivalent requests are " \
      "deduplicated and proactive requests are rate-limited."
    input_schema(
      properties: {
        capability: { type: "string", description: "Versioned capability, e.g. code.read@v1." },
        operation: { type: "string", description: "Versioned operation within the capability." },
        resource_scope: { type: "object", description: "Normalized resource scope; omit for unscoped operations." },
        constraints: { type: "object", description: "Descriptor-supported constraints only (never secrets)." },
        purpose: { type: "string", maxLength: 1000, description: "Why you need this authority, shown to the owner." },
        duration: { type: "string", enum: Permissions::CoworkerPermissionRequest::DURATIONS,
          description: "Narrowest suitable duration. The owner policy and descriptor ceilings decide what is actually offered." }
      },
      required: %w[capability operation purpose]
    )

    class << self
      def call(server_context:, capability:, operation:, purpose:, resource_scope: {}, constraints: {}, duration: nil)
        context = McpToolContext.from_server_context(server_context)
        result = Permissions::CoworkerPermissionRequest.new(
          context:, capability:, operation:, purpose:, resource_scope:, constraints:, duration:,
          origin_message_id: server_context[:current_message]&.id
        ).call
        request = result.request
        server_context[:current_message]&.update_columns(pending_action_id: request.id) if result.created?
        Mcp::Tools.success(
          status: result.status.to_s, authorization_request_id: request&.id,
          offered_durations: result.offered_durations, requested_duration: result.requested_duration,
          grants_authority: false, message: I18n.t("server.permissions.coworker_permission.#{message_key(result.status)}")
        )
      rescue Permissions::CoworkerPermissionRequest::Rejected => error
        Mcp::Tools.invalid(I18n.t("server.permissions.coworker_permission.rejected", reason: "#{error.code}: #{error.message}"))
      end

      private

      def message_key(status) = status == :created ? :requested : status
    end
  end
end
