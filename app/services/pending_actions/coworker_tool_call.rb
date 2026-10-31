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

      descriptor = Mcp::CoworkerToolCatalog.resolve(payload.fetch("tool_name"), chat_session: chat_session)
      raise ArgumentError, "tool is not available to coworkers" unless descriptor
      unless descriptor.ungated || context.granted_capabilities.include?(descriptor.capability.to_s)
        raise ArgumentError, "required grant is no longer present"
      end

      tool = Mcp::Sidecar.chat_tools(chat_session, tier: descriptor.tier)
        .find { |candidate| McpToolRegistry.tool_name_for(candidate) == descriptor.tool_name }
      raise ArgumentError, "tool is no longer available to coworkers" unless tool

      response = Mcp::Tools::AuthorizationSupport.with_coworker_approval_bypass do
        tool.call(**payload.fetch("arguments").symbolize_keys, server_context: server_context)
      end
      raise ArgumentError, response.content.first[:text].to_s if response.error?

      result_text = response.content.filter_map { |item| item[:text] || item["text"] }.join("\n")
      @action.update!(payload: payload.merge("tool_result" => result_text.byteslice(0, 64.kilobytes)))

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
