module PendingActions
  class CoworkerToolCall < Base
    action_key "coworker_tool_call"
    requires_chat_session!

    def execute
      server_context = replay_server_context
      context = McpToolContext.from_server_context(server_context)
      unless context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])
        raise ArgumentError, "coworker context is no longer available"
      end

      entry = McpToolRegistry.entries(surface: :coworker).find { |candidate| candidate.tool_name == payload.fetch("tool_name") }
      raise ArgumentError, "tool is not available to coworkers" unless entry&.mutation
      raise ArgumentError, "required grant is no longer present" unless context.granted_capabilities.include?(entry.capability.to_s)

      response = Mcp::Tools::AuthorizationSupport.with_coworker_approval_bypass do
        entry.tool.call(**payload.fetch("arguments").symbolize_keys, server_context: server_context)
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
    def tool_card_review
      {
        tool_name: payload["tool_name"],
        arguments: payload["arguments"],
        actor: payload["actor"]
      }.compact
    end

    private

    def replay_server_context
      return { chat_session: chat_session } if payload["run_id"].blank?

      run = Run.find_by(id: payload["run_id"])
      raise ArgumentError, "originating run is no longer available" unless run

      { run: run, chat_session: chat_session }
    end
  end
end
