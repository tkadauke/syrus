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

      target = replay_target(payload.fetch("tool_name"))
      raise ArgumentError, "tool is not available to coworkers" unless target
      raise ArgumentError, "required grant is no longer present" unless context.granted_capabilities.include?(target.fetch(:capability).to_s)

      response = Mcp::Tools::AuthorizationSupport.with_coworker_approval_bypass do
        target.fetch(:call).call(**payload.fetch("arguments").symbolize_keys,
          server_context: server_context.merge(pending_action_id: action.id))
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

    def replay_target(tool_name)
      entry = McpToolRegistry.entries(surface: :coworker).find { |candidate| candidate.tool_name == tool_name }
      return { capability: entry.capability, call: entry.tool } if entry&.mutation

      Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set).each do |provider|
        definition = Array(provider.tool_definitions(tier: :essential)).find do |candidate|
          (candidate[:name] || candidate["name"]).to_s == tool_name && (candidate[:mutation] || candidate["mutation"])
        end
        next unless definition

        capability = definition[:capability] || definition["capability"]
        return { capability:, call: ->(server_context:, **arguments) { provider.new.handle(tool_name, arguments, server_context) } }
      end
      nil
    end

    def replay_server_context
      return { chat_session: chat_session } if payload["run_id"].blank?

      run = Run.find_by(id: payload["run_id"])
      raise ArgumentError, "originating run is no longer available" unless run

      { run: run, chat_session: chat_session }
    end
  end
end
