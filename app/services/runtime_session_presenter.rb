# Shared JSON shaping for RuntimeSession/RuntimeControlLease (DOC-17),
# used by both the runtime_* MCP tools (Mcp::Tools::RuntimeSessionToolSupport)
# and the operator-facing Api::V1::App::RuntimeSessionsController, so the
# agent and the Coding Mode Runtime panel see byte-for-byte the same shape.
module RuntimeSessionPresenter
  module_function

  # Bookkeeping keys `metadata` carries for Syrus's own use (e.g.
  # `SyrusBrowser::ArtifactSinks::ChatMedia#stamp_latest_frame!` stashes the
  # captured frame's Document id there so the `frame` action can look it up)
  # but that no consumer -- agent or operator -- should see rendered back as
  # if it were provider-reported metadata like `url`/`port`.
  INTERNAL_METADATA_KEYS = %w[latest_frame_document_id].freeze

  def session_payload(session)
    {
      id: session.id,
      provider_key: session.provider_key,
      display_name: session.display_name,
      state: session.state,
      primary: session.primary,
      workspace_ref: session.workspace_ref,
      capabilities: session.capabilities,
      metadata: session.metadata.except(*INTERNAL_METADATA_KEYS),
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
