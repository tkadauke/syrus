require "mcp"

module Mcp::Tools
  class ListPendingActionsTool < MCP::Tool
    tool_name "list_pending_actions"

    STATES = %w[pending confirmed rejected failed all].freeze
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100
    ID_KEY = /\A[a-z0-9_]+_ids?\z/

    description <<~DESC
      List pending actions created in the current chat, including resolved
      outcomes. Returns compact target identifiers and status details without
      exposing raw tool arguments.
    DESC

    input_schema(
      properties: {
        state: { type: "string", enum: STATES, default: "pending", description: "Action state to return, or all." },
        job_id: { type: "integer", description: "Only actions targeting this Job, including grouped job_ids." },
        limit: { type: "integer", minimum: 1, default: DEFAULT_LIMIT, description: "Maximum rows (capped at 100)." }
      }
    )

    class << self
      def call(server_context:, state: "pending", job_id: nil, limit: DEFAULT_LIMIT)
        chat_session = server_context.fetch(:chat_session)
        state = state.to_s
        return Mcp::Tools.invalid("state must be one of: #{STATES.join(', ')}") unless STATES.include?(state)

        limit = normalized_limit(limit)
        return Mcp::Tools.invalid("limit must be a positive integer") unless limit

        job_id = normalized_job_id(job_id)
        return Mcp::Tools.invalid("job_id must be an integer") if job_id == false

        actions = chat_session.pending_actions.where(user_id: chat_session.user_id)
        actions = actions.where(state: state) unless state == "all"
        actions = actions.order(created_at: :desc, id: :desc)
        actions = actions.select { |action| targets_job?(action, job_id) } if job_id

        rows = actions.first(limit).map { |action| serialize(action) }
        Mcp::Tools.success(actions: rows, count: rows.length, state: state, limit: limit)
      end

      private

      def normalized_limit(value)
        parsed = Integer(value, exception: false)
        parsed&.positive? ? [ parsed, MAX_LIMIT ].min : nil
      end

      def normalized_job_id(value)
        return nil if value.nil?

        Integer(value, exception: false) || false
      end

      def targets_job?(action, job_id)
        payload = action.payload.to_h
        payload["job_id"].to_i == job_id || Array(payload["job_ids"]).map(&:to_i).include?(job_id)
      end

      def serialize(action)
        payload = action.payload.to_h
        row = {
          pending_action_id: action.id,
          action: action.action.presence || action.action_type,
          state: action.state,
          execution_status: action.execution_status,
          group_id: action.pending_action_group_id,
          created_at: action.created_at&.iso8601,
          resolved_at: resolved_at(action)&.iso8601
        }
        row[:target_ids] = payload.select { |key, _value| key.to_s.match?(ID_KEY) } if payload.any?
        reason = action.reason.presence || payload["reason"].presence || payload["message"].presence || action.purpose.presence
        row[:reason] = reason.to_s.truncate(500) if reason
        row[:error_summary] = action.execution_error.to_s.truncate(300) if action.execution_error.present?
        row.compact
      end

      def resolved_at(action)
        action.execution_finished_at || action.confirmed_at || action.rejected_at || action.cancelled_at ||
          action.non_actionable_at || action.dismissed_at
      end
    end
  end
end
