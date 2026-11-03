module Permissions
  # A coworker asking its owner to revoke a durable rule that applies to that
  # coworker. This only creates an owner-confirmed pending action; the rule is
  # neither revoked nor edited here.
  class CoworkerPermissionRevocationRequest
    ACTION = "coworker_permission_revocation".freeze
    MAX_PENDING = 3

    Result = Data.define(:status, :pending_action)

    # The one place that decides "applies to this coworker": an exact agent
    # selector naming the coworker. Role, chat-type and other selectors never
    # qualify, so a coworker cannot ask about rules that govern anyone else.
    def self.targets?(rule, coworker)
      rule.subject_selector_type == "agent" && rule.subject_selector_id == coworker.id.to_s &&
        rule.owner_user_id == coworker.owner_user_id
    end

    def initialize(context:, permission_rule_id:, rationale: nil, origin_message: nil)
      @context = context
      @permission_rule_id = permission_rule_id
      @rationale = rationale.to_s.strip.presence
      @origin_message = origin_message
    end

    def call
      unless context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]) && coworker &&
          coworker.owner_user_id == context.user.id
        raise CoworkerPermissionRequest::Rejected.new(:not_a_coworker, "only a coworker can request revocation for itself")
      end
      raise CoworkerPermissionRequest::Rejected.new(:chat_required, "a chat session is required to ask the owner") unless context.chat_session

      rule = Management.new(context.user).rules.find_by(id: @permission_rule_id)
      unless rule && self.class.targets?(rule, coworker)
        raise CoworkerPermissionRequest::Rejected.new(:rule_not_found, "no active permission rule applies to this coworker with that id")
      end

      existing = open_requests.find { |pending| pending.payload["permission_rule_id"] == rule.id }
      return Result.new(status: :deduplicated, pending_action: existing) if existing
      if open_requests.length >= MAX_PENDING
        raise CoworkerPermissionRequest::Rejected.new(:too_many_pending, "too many revocation requests are already waiting for the owner")
      end

      pending = context.chat_session.pending_actions.create!(
        action: ACTION, requested_by: "agent", subject: coworker,
        payload: { "permission_rule_id" => rule.id, "capability" => rule.capability, "operation" => rule.operation,
                   "rationale" => rationale }.compact
      )
      origin_message&.update_columns(pending_action_id: pending.id)
      CoworkerAudit.record!(:coworker_permission_revocation_requested, owner: context.user, coworker:,
        permission_rule_id: rule.id, capability: rule.capability, operation: rule.operation, pending_action_id: pending.id)
      Result.new(status: :created, pending_action: pending)
    end

    private

    attr_reader :context, :rationale, :origin_message

    def coworker = context.agent_actor

    def open_requests
      @open_requests ||= ChatPendingAction.where(user: context.user, action: ACTION, state: "pending",
        subject_type: coworker.class.name, subject_id: coworker.id).to_a
    end
  end
end
