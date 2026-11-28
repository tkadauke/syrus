require "digest"

module Coworkers
  # Evaluates publication independently from the build request. The returned
  # grant is bound to the exact candidate and evidence fingerprint and is the
  # only value EnvironmentLifecycle accepts as publication authority.
  class EnvironmentPublicationAuthority
    Grant = Data.define(:environment_id, :revision_id, :fingerprint, :decision, :expires_at)
    Result = Data.define(:decision, :subject, :risk_summary, :grant, :pending_action, :lease_expires_at) do
      def allowed? = decision == :allow
      def ask? = decision == :ask
      def denied? = decision == :deny
    end

    def initialize(environment, role: AgentRole::COWORKER, now: Time.current)
      @environment = environment
      @role = role
      @now = now
    end

    def call(revision = environment.candidate_revision, consume: true)
      validate_candidate!(revision)
      risk = EnvironmentPublicationRisk.new(environment, revision).call
      subject = permission_subject(revision, risk.deltas)
      descriptor = descriptor_for_publish
      arguments = subject.permission_arguments
      context = evaluation_context
      authorization = Syrus::Host::PermissionAuthorization.call(
        owner: environment.coworker.owner_user, descriptor:, role:, arguments:, context:, consume:
      )
      decision = authorization.decision
      expiry = authorization.lease_expires_at
      fingerprint = fingerprint_for(arguments)
      grant = Grant.new(environment_id: environment.id, revision_id: revision.id, fingerprint:,
                        decision:, expires_at: expiry) if decision == :allow
      pending = pending_action(revision, subject, risk, fingerprint) if decision == :ask
      Result.new(decision:, subject:, risk_summary: risk.summary, grant:, pending_action: pending,
                 lease_expires_at: expiry)
    end

    def valid_grant?(grant, revision)
      return false unless grant.is_a?(Grant) && grant.decision == :allow
      return false if grant.expires_at && grant.expires_at <= now
      return false unless grant.environment_id == environment.id && grant.revision_id == revision.id

      risk = EnvironmentPublicationRisk.new(environment, revision).call
      subject = permission_subject(revision, risk.deltas)
      descriptor = descriptor_for_publish
      grant.fingerprint == fingerprint_for(subject.permission_arguments)
    end

    private

    attr_reader :environment, :role, :now

    def validate_candidate!(revision)
      unless Feature.coworker_custom_environments_enabled?
        raise Coworkers::EnvironmentBuildRequest::Disabled, "coworker custom environments are not enabled"
      end
      unless revision&.candidate? && revision.environment == environment && revision.runtime_image&.verified_candidate?
        raise Coworkers::EnvironmentRevision::InvalidTransition, "publication authority requires the exact verified candidate"
      end
    end

    def descriptor_for_publish
      Coworkers::EnvironmentPermissionProvider.permission_capability_descriptors.find do |item|
        item.operation == Coworkers::EnvironmentPermissionProvider.operation(:publish)
      end || raise("environment publication permission descriptor is unavailable")
    end

    def permission_subject(revision, risk_deltas)
      attempt = revision.runtime_image.runtime_image_verification_attempts.order(number: :desc).first
      Coworkers::EnvironmentPermissionSubject.new(
        coworker_id: environment.coworker_id, owner_user_id: environment.coworker.owner_user_id,
        environment_id: environment.id, revision_id: revision.id, source_digest: revision.source_digest,
        base_digest: revision.base_release&.digest, image_digest: revision.runtime_image.digest,
        policy_result: attempt&.decision || attempt&.state, risk_deltas:
      )
    end

    def evaluation_context
      { role:, agent_id: environment.coworker_id, agent_actor: environment.coworker,
        subject_selector_type: "agent", subject_selector_id: environment.coworker_id.to_s }
    end

    def pending_action(revision, subject, risk, fingerprint)
      {
        "action" => "publish_coworker_environment", "status" => "pending",
        "environment_id" => environment.id, "revision_id" => revision.id,
        "image_digest" => subject.image_digest, "invocation_fingerprint" => fingerprint,
        "risk_summary" => risk.summary, "risk_deltas" => risk.deltas
      }.freeze
    end

    def fingerprint_for(arguments)
      normalized = Coworkers::EnvironmentPermissionProvider.normalize(arguments)
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(normalized))}"
    end
  end
end
