module Mcp::Tools
  # Shared helpers for the generic runtime_* MCP tools (DOC-17). These are
  # Coding Mode's entry point onto RuntimeSession/RuntimeControlLease and the
  # registered RuntimeSessionProvider for whichever session a call targets —
  # repository/session resolution, provider dispatch, and JSON payload
  # shaping live here so the individual tool classes stay thin wrappers
  # around one call each.
  module RuntimeSessionToolSupport
    private

    def require_coding_mode(chat_session)
      return Mcp::Tools.invalid("Coding Mode is not enabled") unless Feature.coding_mode_enabled?
      return Mcp::Tools.invalid("runtime_* tools are only available in Coding Mode chats") unless chat_session.coding?

      nil
    end

    def resolve_repository(chat_session)
      chat_session.repository
    end

    # Resolves the RuntimeSession a call operates on: an explicit session_id,
    # else the chat's primary active session, else its most recently created
    # active session. Mirrors SyrusBrowser::SessionContext's own
    # provider-scoped default, generalized across providers.
    def resolve_runtime_session(chat_session, session_id)
      scope = chat_session.runtime_sessions
      session = if session_id.present?
        scope.find_by(id: session_id)
      else
        active = scope.active
        active.primary.first || active.order(created_at: :desc).first
      end

      unless session
        message = session_id.present? ? "runtime session #{session_id} not found" : "no active runtime session; call runtime_start first"
        return [ nil, Mcp::Tools.invalid(message) ]
      end

      [ session, nil ]
    end

    def provider_instance_for(runtime_session)
      RuntimeSessionProviders.for(runtime_session.provider_key).new
    end

    # Dispatches a plain provider call (no RuntimeSession state transition)
    # and normalizes both configuration and runtime errors into an `invalid`
    # tool response instead of raising out of the sidecar.
    def with_provider_call(runtime_session)
      provider = provider_instance_for(runtime_session)
      Mcp::Tools.success(yield(provider))
    rescue RuntimeSessionProviders::ConfigurationError => e
      Mcp::Tools.invalid(e.message)
    rescue StandardError => e
      Mcp::Tools.invalid("#{e.class}: #{e.message}")
    end

    def normalize_options(options)
      (options || {}).to_h.symbolize_keys
    end

    def runtime_session_payload(session)
      {
        id: session.id,
        provider_key: session.provider_key,
        display_name: session.display_name,
        state: session.state,
        primary: session.primary,
        workspace_ref: session.workspace_ref,
        capabilities: session.capabilities,
        metadata: session.metadata,
        stream_url: session.stream_url,
        latest_frame_url: session.latest_frame_url,
        latest_frame_at: session.latest_frame_at&.iso8601,
        last_error: session.last_error,
        active_agent_input_lease: lease_payload(session.active_agent_input_lease)
      }
    end

    def lease_payload(lease)
      return nil unless lease

      {
        id: lease.id,
        owner: lease.owner,
        owner_ref: lease.owner_ref,
        mode: lease.mode,
        reason: lease.reason,
        state: lease.state,
        acquired_at: lease.acquired_at&.iso8601,
        expires_at: lease.expires_at&.iso8601,
        cancellable: lease.cancellable
      }
    end
  end
end
