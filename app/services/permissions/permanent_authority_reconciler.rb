module Permissions
  # Resolves pending requests that an already-committed permanent rule now
  # authorizes. Candidate narrowing is deliberately conservative; the policy
  # evaluator remains the source of truth for actual coverage.
  class PermanentAuthorityReconciler
    def self.call(...) = new(...).call

    def initialize(rule:, source_request:)
      @rule = rule
      @source_request = source_request
    end

    def call
      return [] unless eligible_rule?

      candidate_scope.find_each.filter_map { |candidate| reconcile(candidate) }
    end

    private

    attr_reader :rule, :source_request

    def eligible_rule?
      rule.is_a?(PermissionRule) && rule.persisted? && rule.revoked_at.nil? && rule.policy == "allow"
    end

    def candidate_scope
      ChatPendingAction.where(
        request_kind: "authorization_request", state: "pending",
        user_id: source_request.user_id, subject_type: source_request.subject_type,
        subject_id: source_request.subject_id, runtime_role: source_request.runtime_role,
        repository_id: source_request.repository_id
      ).where.not(id: source_request.id).order(:id)
    end

    def reconcile(candidate)
      ready = candidate.with_lock do
        candidate.reload(lock: true)
        next false unless candidate.pending? && candidate.actionable?

        items = candidate.authorization_items.order(:id).lock.to_a
        next false if items.empty? || items.any? { |item| item.kind != "operation" || !item.actionable? }

        evaluations = items.map { |item| [ item, evaluate(candidate, item) ] }
        next false unless evaluations.all? { |_item, authorization| covered_by_rule?(authorization) }

        evaluations.each do |item, _authorization|
          item.decide!("approved", principal: source_request.user, duration: "permanent",
            reason: "Authorized by an existing permanent permission rule", resulting_authority: rule)
          issue_invocation!(candidate, item) unless candidate.action == PermissionRequest::ACTION
        end

        if candidate.action == PermissionRequest::ACTION
          candidate.update!(state: "confirmed", confirmed_at: Time.current)
          items.each { |item| audit_permission_grant(candidate, item) }
          false
        else
          candidate.reload(lock: true).ready_for_authorized_invocation?
        end
      end

      candidate if ready && candidate.enqueue_confirmation!(user: source_request.user)
    rescue Catalog::UnknownCapability, ActiveRecord::RecordNotFound, ArgumentError => error
      Rails.logger.info("[PermanentAuthorityReconciler] skipped request=#{candidate.id} error=#{error.class}: #{error.message}")
      nil
    end

    def evaluate(candidate, item)
      descriptor = Catalog.find!(
        capability: "#{item.capability}@v#{item.capability_version}",
        operation: "#{item.operation}@v#{item.operation_version}"
      )
      Management.new(source_request.user).authorize(
        descriptor:, role: candidate.runtime_role, resource_scope: item.resource_scope,
        arguments: item.normalized_arguments, context: evaluation_context(candidate)
      )
    end

    def covered_by_rule?(authorization)
      authorization.authorized? && authorization.decision.decisive_rule&.id == rule.to_policy_rule.id
    end

    def issue_invocation!(candidate, item)
      AuthorizedInvocation.issue!(
        pending_action_item: item, authority: rule,
        tool_name: candidate.payload.fetch("tool_name"),
        execution_authority: evaluation_context(candidate),
        audit_payload: {
          pending_action_id: candidate.id,
          reconciled_from_pending_action_id: source_request.id,
          permission_rule_id: rule.id
        }
      )
    end

    def audit_permission_grant(candidate, item)
      return unless candidate.runtime_role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]) && candidate.subject

      CoworkerAudit.record!(:coworker_permission_granted,
        owner: source_request.user, coworker: candidate.subject, authorization_request_id: candidate.id,
        capability: item.capability, operation: item.operation,
        authority: SmartDecision.authority_reference(item), duration: "permanent")
    end

    def evaluation_context(candidate)
      subject = RuleDraft.request_subject(candidate)
      {
        role: candidate.runtime_role,
        agent_id: (candidate.subject_id if subject["subject_selector_type"] == "agent"),
        subject_selector_type: subject["subject_selector_type"],
        subject_selector_id: subject["subject_selector_id"],
        subject_repository_id: candidate.repository_id,
        chat_session_id: candidate.chat_session_id,
        job_id: (candidate.origin_id if candidate.origin_type == "Job")
      }.compact
    end
  end
end
