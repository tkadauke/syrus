module PendingActions
  class CoworkerToolCall < Base
    action_key "coworker_tool_call"
    requires_chat_session!

    def authorize_execution!
      return super unless @action.authorization_request?

      unless @action.ready_for_authorized_invocation?
        raise ArgumentError, "authorization request prerequisites are not approved"
      end

      operation = @action.authorization_items.find_by!(kind: "operation")
      descriptor = permission_descriptor
      fingerprint = Permissions::InvocationFingerprint.call(
        descriptor:, arguments: payload.fetch("arguments")
      )
      unless ActiveSupport::SecurityUtils.secure_compare(operation.invocation_fingerprint, fingerprint)
        raise ArgumentError, "approved invocation no longer matches the requested arguments"
      end
    end

    def execute
      server_context = replay_server_context
      context = McpToolContext.from_server_context(server_context)
      unless context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])
        raise ArgumentError, "coworker context is no longer available"
      end

      descriptor = Mcp::CoworkerToolCatalog.resolve(payload.fetch("tool_name"), chat_session: chat_session)
      raise ArgumentError, "tool is not available to coworkers" unless descriptor

      tool = Mcp::Sidecar.chat_tools(chat_session, tier: descriptor.tier, agent_actor: action.subject)
        .find { |candidate| McpToolRegistry.tool_name_for(candidate) == descriptor.tool_name }
      raise ArgumentError, "tool is no longer available to coworkers" unless tool

      invocation = @action.authorization_items.find_by!(kind: "operation").authorized_invocation
      raise ArgumentError, "authorized invocation is missing" unless invocation
      fingerprint = Permissions::InvocationFingerprint.call(
        descriptor: permission_descriptor, arguments: payload.fetch("arguments")
      )
      claim_key = "coworker-pending-action-#{@action.id}"
      claim = invocation.claim!(
        fingerprint:, claimant: action.subject, claim_key:,
        origin_resumable: ->(_) { origin_resumable? },
        revalidate: ->(_) { revalidate_authority(context) }
      )
      raise ArgumentError, "authorized invocation is no longer available (#{claim.status})" unless claim.claimed?

      server_context = server_context.merge(
        authorized_invocation_id: invocation.id,
        authorized_invocation_claim_key: claim_key
      )
      response = tool.call(**payload.fetch("arguments").symbolize_keys, server_context: server_context)
      if response.error?
        invocation.complete!(claim_key:, status: :failed)
        raise ArgumentError, response.content.first[:text].to_s
      end
      invocation.complete!(claim_key:, status: :succeeded)

      result_text = response.content.filter_map { |item| item[:text] || item["text"] }.join("\n")
      @action.update!(payload: payload.merge("tool_result" => result_text.byteslice(0, 64.kilobytes)))

      nil
    rescue StandardError
      invocation&.complete!(claim_key:, status: :failed) if invocation&.claimed?
      raise
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

    def permission_descriptor
      catalog_entry = Mcp::CoworkerToolCatalog.resolve(payload.fetch("tool_name"), chat_session: chat_session)
      raise ArgumentError, "tool is not available to coworkers" unless catalog_entry

      descriptor = if catalog_entry.tool
        McpToolRegistry.entries(surface: :coworker).find { |entry| entry.tool == catalog_entry.tool }&.descriptor
      else
        Permissions::CapabilityDescriptorAdapter.for_plugin_definition(catalog_entry.definition)
      end
      descriptor || raise(ArgumentError, "tool has no permission descriptor")
    end

    def replay_server_context
      return { chat_session: chat_session, agent_actor: action.subject } if payload["run_id"].blank?

      run = Run.find_by(id: payload["run_id"])
      raise ArgumentError, "originating run is no longer available" unless run

      { run: run, chat_session: chat_session }
    end

    def origin_resumable?
      return action.origin.deleted_at.nil? if action.origin.is_a?(ChatSession)
      return !action.origin.state.in?(Job::TERMINAL_STATES) if action.origin.is_a?(Job)
      return !action.origin.terminal? if action.origin.respond_to?(:terminal?)

      action.origin.present?
    end

    def revalidate_authority(context)
      result = Permissions::Management.new(context.user).authorize(
        descriptor: permission_descriptor, role: context.role,
        resource_scope: @action.authorization_items.find_by!(kind: "operation").resource_scope,
        arguments: payload.fetch("arguments"),
        context: {
          role: context.role, agent_id: context.agent_actor.id,
          subject_selector_type: "agent", subject_selector_id: context.agent_actor.id.to_s,
          subject_repository_id: context.repository&.id,
          chat_session_id: context.chat_session&.id, job_id: context.job&.id
        }.compact
      )
      result.authorized? ? true : "permission_policy_#{result.decision.policy}"
    end
  end
end
