module Coworkers
  # Evaluates publication independently from candidate construction. A build
  # request or successful build is evidence, never publication authority.
  class EnvironmentPublicationAuthority
    Result = Data.define(:decision, :subject, :risk_summary, :action, :lease, :expires_at) do
      def allow? = decision == :allow
      def ask? = decision == :ask
      def deny? = decision == :deny
      def pending_publication? = action == :pending_publication
    end

    def initialize(owner:, coworker:, environment:, revision:, risk:, role: AgentRole::COWORKER,
      context: {}, now: Time.current)
      @owner = owner
      @coworker = coworker
      @environment = environment
      @revision = revision
      @risk = risk
      @role = role
      @context = context.to_h
      @now = now
    end

    def call
      subject = permission_subject
      return result(:deny, subject, :retain_candidate) unless eligible?(subject)

      authorization = Syrus::Host::PermissionManagement.new(owner).authorize(
        descriptor:, role:, resource_scope: {}, arguments: subject.permission_arguments,
        context: evaluation_context
      )
      decision = authorization.decision.policy
      action = { allow: :publish, ask: :pending_publication, deny: :retain_candidate }.fetch(decision)
      result(decision, subject, action, authorization.lease)
    end

    private

    attr_reader :owner, :coworker, :environment, :revision, :risk, :role, :context, :now

    def descriptor
      @descriptor ||= EnvironmentPermissionProvider.permission_capability_descriptors.find do |candidate|
        candidate.operation == EnvironmentPermissionProvider.operation(:publish)
      end || raise("coworker environment publication permission descriptor is unavailable")
    end

    def permission_subject
      EnvironmentPermissionSubject.new(
        coworker_id: coworker.id, owner_user_id: owner.id, environment_id: environment.id,
        revision_id: revision.id, source_digest: revision.source_digest,
        base_digest: risk.deltas.dig("base", "after"), image_digest: revision.runtime_image&.digest,
        policy_result: risk.summary.fetch("policy_result"), risk_deltas: risk.deltas
      )
    end

    def eligible?(subject)
      EnvironmentPermissionProvider.feature_gate_allows?(:publish, subject:) &&
        revision.candidate? && revision.runtime_image&.pullable?
    end

    def evaluation_context
      context.merge(
        role:, agent_id: coworker.id, agent_actor: coworker,
        subject_selector_type: "agent", subject_selector_id: coworker.id.to_s,
        subject_repository_id: context[:subject_repository_id]
      ).compact
    end

    def result(decision, subject, action, lease = nil)
      Result.new(decision: decision.to_sym, subject:, risk_summary: risk.summary, action:,
                 lease:, expires_at: lease&.expires_at)
    end
  end
end
