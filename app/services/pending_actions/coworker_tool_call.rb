module PendingActions
  class CoworkerToolCall < Base
    action_key "coworker_tool_call"
    requires_chat_session!

    def execute
      context = McpToolContext.from_chat_session(chat_session)
      raise ArgumentError, "coworker chat is no longer available" unless context.role == AgentRole::COWORKER_CHAT

      entry = McpToolRegistry.entries(surface: :coworker).find { |candidate| candidate.tool_name == payload.fetch("tool_name") }
      raise ArgumentError, "tool is not available to coworkers" unless entry&.mutation
      raise ArgumentError, "required grant is no longer present" unless context.granted_capabilities.include?(entry.capability.to_s)

      response = Mcp::Tools::AuthorizationSupport.with_coworker_approval_bypass do
        entry.tool.call(**payload.fetch("arguments").symbolize_keys, server_context: { chat_session: chat_session })
      end
      raise ArgumentError, response.content.first[:text].to_s if response.error?

      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "tool_name is required") unless payload["tool_name"].present?
      errors.add(:payload, "arguments must be an object") unless payload["arguments"].is_a?(Hash)
    end

    def presentation_label = "Approve coworker action"
    def presentation_detail = payload["tool_name"].to_s.humanize
  end
end
