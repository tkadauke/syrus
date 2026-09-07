# Shared JSON shaping for RuntimeSession/RuntimeControlLease (DOC-17),
# used by both the runtime_* MCP tools (Mcp::Tools::RuntimeSessionToolSupport)
# and the operator-facing Api::V1::App::RuntimeSessionsController, so the
# agent and the Coding Mode Runtime panel see byte-for-byte the same shape.
module RuntimeSessionPresenter
  module_function

  def session_payload(session)
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
