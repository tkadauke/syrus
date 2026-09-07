require "mcp"

module Mcp::Tools
  class RuntimeAcquireControlTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_acquire_control"

    description <<~DESC
      Acquire a Runtime Control Lease (DOC-17's Shared Human/Agent Control)
      on a Runtime Session before sending input, build, or lifecycle
      operations that must not race the operator. `mode` is "input", "build",
      or "lifecycle" -- input is serialized separately from build/lifecycle.
      Leases are short-lived (15-60s, default 30s) and the operator can
      always abort agent control immediately. Call runtime_release_control
      when done.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the chat's primary active session." },
        mode: { type: "string", description: "Lease mode: \"input\", \"build\", or \"lifecycle\"." },
        reason: { type: "string", description: "Short reason for the lease, recorded for the audit trail and operator UI." },
        duration_seconds: { type: "integer", description: "Requested lease duration, clamped to 15-60s. Defaults to 30s." }
      },
      required: %w[mode reason]
    )

    class << self
      def call(mode:, reason:, session_id: nil, duration_seconds: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        guard = require_coding_mode(chat_session)
        return guard if guard

        session, error = resolve_runtime_session(chat_session, session_id)
        return error if error

        unless RuntimeControlLease::MODES.include?(mode) && mode != "observe_only"
          return Mcp::Tools.invalid("mode must be one of: input, build, lifecycle")
        end

        lease = RuntimeControlLease.acquire!(
          runtime_session: session,
          owner: "agent",
          owner_ref: "coding_mode_chat:#{chat_session.id}",
          mode: mode,
          reason: reason,
          duration_seconds: duration_seconds
        )

        Mcp::Tools.success(lease_payload(lease))
      rescue RuntimeControlLease::Conflict => e
        Mcp::Tools.invalid(e.message)
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
