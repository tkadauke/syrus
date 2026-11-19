require "mcp"
module Mcp::Tools
  class CancelAuthorizationRequestTool < MCP::Tool
    extend PermissionToolSupport
    tool_name "cancel_authorization_request"
    description <<~DESC
      Request cancellation of an obsolete authorization request without
      creating a deny rule. Identify the request by capability and optional
      operation, or omit selectors when this chat has exactly one cancellable
      authorization request. Use the numeric ID only as an exact handle when
      semantic selectors are ambiguous; never quote that internal handle to the
      operator. Cancelling only withdraws the agent's own request, so it takes
      effect immediately without operator confirmation.
    DESC
    input_schema(properties: {
      authorization_request_id: { type: "integer", description: "Exact internal handle for an ambiguous authorization request." },
      capability: { type: "string", description: "Capability requested, such as code.read@v1." },
      operation: { type: "string", description: "Operation requested within the capability." },
      rationale: { type: "string", maxLength: 1000 }
    })

    class << self
      def call(server_context:, authorization_request_id: nil, capability: nil, operation: nil, rationale: nil)
        request = resolve_request(server_context.fetch(:chat_session), authorization_request_id:, capability:, operation:)
        return request unless request.is_a?(ChatPendingAction)

        # Withdrawing a request only reduces authority: an essential operation
        # that acts directly instead of asking the operator to confirm it.
        label = request_label(request)
        return Mcp::Tools.invalid("authorization request is no longer cancellable") unless request.cancel!(user: request.user)

        Mcp::Tools.success(cancelled: true, authorization_request: label, rationale:)
      end

      private

      def resolve_request(chat_session, authorization_request_id:, capability:, operation:)
        requests = chat_session.pending_actions.where(
          user_id: chat_session.user_id,
          request_kind: "authorization_request",
          state: "pending"
        )
        if authorization_request_id.present?
          request = requests.find_by(id: Integer(authorization_request_id, exception: false))
          return request || Mcp::Tools.invalid("authorization request not found in this chat")
        end

        requests = requests.joins(:authorization_items)
        requests = requests.where(pending_action_items: version_filter(:capability, capability)) if capability.present?
        requests = requests.where(pending_action_items: version_filter(:operation, operation)) if operation.present?
        requests = requests.distinct.to_a
        return requests.first if requests.one?
        return Mcp::Tools.invalid("no matching cancellable authorization request was found in this chat") if requests.empty?

        candidates = requests.map { |request| request_summary(request) }.join("; ")
        Mcp::Tools.invalid("more than one authorization request matches; distinguish it by capability and operation: #{candidates}")
      end

      def version_filter(attribute, value)
        name, version = value.to_s.match(/\A(.+?)(?:@v(\d+))?\z/).captures
        { attribute => name }.tap { |filter| filter["#{attribute}_version"] = version.to_i if version }
      end

      def request_summary(request)
        item = request.authorization_items.first
        purpose = item&.purpose.presence || request.purpose.presence || "no purpose provided"
        "#{request_label(request)} (purpose: #{ToolPayloadRedactor.redact_text(purpose).truncate(200)})"
      end

      def request_label(request)
        item = request.authorization_items.first
        return "requested authority" unless item

        [ versioned(item.capability, item.capability_version), versioned(item.operation, item.operation_version) ].compact.join(" / ")
      end

      def versioned(name, version)
        "#{name}@v#{version}" if name.present?
      end
    end
  end
end
