module Mcp::Tools
  # Shared plumbing for chat-sidecar tools that accept either a single id
  # (unchanged, synchronous-looking behavior) or an array of ids (batched
  # into one PendingActionGroup the operator confirms/rejects as a unit,
  # instead of one pending action per id).
  module BulkPendingActionToolSupport
    include ProposalToolSupport

    private

    # Resolves exactly one of a singular id param or a plural ids param into
    # a normalized, deduped array of integers. Returns
    # [ids, bulk?, error_response]; callers should `return error if error`.
    def resolve_ids(id:, ids:, param_name:)
      if id.present? && !ids.nil?
        return [ nil, false, Mcp::Tools.invalid("provide only one of #{param_name} or #{param_name}s") ]
      end

      if !ids.nil?
        values = Array(ids)
        normalized = values.filter_map { |value| Integer(value, exception: false) }
        return [ nil, true, Mcp::Tools.invalid("#{param_name}s must be an array of integers") ] if normalized.size != values.size
        return [ nil, true, Mcp::Tools.invalid("#{param_name}s must not be empty") ] if normalized.empty?

        [ normalized.uniq, true, nil ]
      else
        normalized = Integer(id, exception: false)
        return [ nil, false, Mcp::Tools.invalid("#{param_name} is required") ] unless normalized

        [ [ normalized ], false, nil ]
      end
    end

    def create_pending_action_group!(server_context:, chat_session:, member_attributes:, reason: nil)
      group = nil
      ApplicationRecord.transaction do
        group = PendingActionGroup.create_with_members!(
          chat_session: chat_session,
          member_attributes: member_attributes,
          reason: reason
        )
        attach_pending_action_to_current_message!(server_context, group.chat_pending_actions.first)
      end
      group
    end

    def bulk_action_response(group:, message:)
      members = group.chat_pending_actions.to_a
      anchor = members.first

      Mcp::Tools.success(
        pending_action_group_id: group.id,
        pending_action_id: anchor.id,
        pending_confirmation_id: anchor.id,
        state: group.state,
        member_count: members.size,
        message: message
      )
    end
  end
end
