# Owns the Coworkers side of an environment revision's lifecycle. Generic
# image availability and audit records remain authoritative in the Runtime
# Image Service; this service only projects them into plugin-owned pointers.
class Coworkers::EnvironmentLifecycle
  INCOMPATIBLE = "environment_incompatible".freeze

  def initialize(environment, now: Time.current)
    @environment = environment
    @now = now
  end

  def reconcile_build!(revision)
    @environment.with_lock do
      revision.reload(lock: true)
      request = revision.build_request
      return unless request

      case request.state
      when "verifying" then begin_verification!(revision)
      when "succeeded" then accept_candidate!(revision, request.result)
      when "rejected" then reject!(revision, code: request.result&.error_code || "build_rejected")
      when "failed", "canceled" then fail_build!(revision, request.result&.error_code || "build_#{request.state}")
      end
    end
  end

  def publish!(revision = @environment.candidate_revision, actor: "system", authority:)
    raise Coworkers::EnvironmentRevision::InvalidTransition, "no candidate revision is available" unless revision
    raise Coworkers::EnvironmentBuildRequest::Disabled, "coworker custom environments are not enabled" unless Feature.coworker_custom_environments_enabled?

    published = @environment.with_lock do
      revision.reload(lock: true)
      image = revision.runtime_image
      if already_published?(revision, image)
        audit("publication_replayed", revision, actor: actor, code: "already_active")
        return revision
      end
      unless revision.candidate? && image&.pullable?
        raise Coworkers::EnvironmentRevision::InvalidTransition, "only a pullable candidate can be published"
      end
      # Serialize activation with generic deletion/revocation. Revocation
      # commits terminal state under this lock before provider cleanup, while
      # deletion holds it across provider removal and its durable transition.
      image.lock!
      unless image.pullable?
        raise Coworkers::EnvironmentRevision::InvalidTransition, "only a pullable candidate can be published"
      end
      # Raising inside the lock would roll the rejection back, leaving an
      # incompatible candidate publishable; commit it, then refuse.
      unless compatible_now?(revision)
        mark_incompatible!(revision)
        next nil
      end
      attestation = current_attestation!(revision)
      attestation.lock!
      unless attestation.valid_at?(@now)
        raise Coworkers::EnvironmentRevision::InvalidTransition, "candidate has no current accepted verification attestation"
      end
      authority = Coworkers::EnvironmentPublicationAuthority.revalidate!(
        authority, owner: @environment.coworker.owner_user, coworker: @environment.coworker,
        environment: @environment, revision:, now: @now
      )

      previous = @environment.active_revision
      previous_activation = @environment.active_activation
      previous.transition_to!(:retired) if previous&.active?
      revision.transition_to!(:active)
      event = audit("published", revision, actor: actor)
      activation = @environment.activations.create!(
        revision:, runtime_image: image, previous_activation:, verification_attestation: attestation,
        authority_lease: authority.lease, inherited_from_activation: authority.inherited_from,
        source_digest: revision.source_digest, image_digest: image.digest,
        authority_kind: authority.inherited_from ? "inherited" : "permission",
        actor: actor.to_s, activated_at: @now
      )
      @environment.transition_to!(:active, active_revision: revision, active_runtime_image: image,
                                  active_activation: activation,
                                  candidate_revision: nil, candidate_runtime_image: nil,
                                  last_error_code: nil, last_audit_event: event)
      Syrus::Host::RuntimeImages.retain(image, reason: "active coworker environment", actor: actor)
      Coworkers::EnvironmentRecovery.new(@environment).refresh_retention!(actor: actor)
      publish_event("activated", revision)
      revision
    end
    raise Coworkers::EnvironmentRevision::InvalidTransition, "candidate is incompatible with the active runtime ABI" unless published

    published
  end

  def reject!(revision, code: "verification_rejected", actor: "system")
    begin_verification!(revision)
    transition_revision!(revision, :rejected)
    clear_candidate!(revision, state: :failed, code: code, event: audit("rejected", revision, actor: actor, code: code))
    publish_event("rejected", revision)
  end

  def revoke!(revision, reason:, actor: "system", severity: :normal)
    severity = severity.to_s == "severe" ? "severe" : "standard"
    if severity == "severe" && revision.runtime_image&.digest.blank?
      raise Coworkers::EnvironmentRevision::InvalidTransition, "severe revocation requires an affected image digest"
    end
    result, changed = @environment.with_lock do
      revision.reload(lock: true)
      already_revoked = revision.revoked? && @environment.active_revision_id != revision.id &&
        @environment.candidate_revision_id != revision.id
      if already_revoked
        [ revision, false ]
      else
        [ revoke_locked!(revision, reason: reason, actor: actor, severity: severity), true ]
      end
    end
    terminate_affected_turns!(revision, reason:) if changed && severity == "severe"
    result
  end

  def rollback!(failed_activation: @environment.active_activation, actor: "system")
    Coworkers::EnvironmentRecovery.new(@environment, now: @now)
      .rollback!(failed_activation:, actor:)
  end

  # Pausing a coworker blocks its work at the coworker state boundary. Keep
  # image pointers intact so resuming does not silently discard a published
  # environment or a verified candidate.
  def suspend!(actor: "system")
    @environment.with_lock do
      event = audit("suspended", @environment.active_revision || @environment.candidate_revision, actor: actor)
      @environment.update!(last_audit_event: event) if event
    end
  end

  def disable!(actor: "system")
    @environment.with_lock do
      active = @environment.active_revision
      candidate = @environment.candidate_revision
      active.transition_to!(:retired) if active&.active?
      candidate.transition_to!(:retired) if candidate&.candidate?
      event = audit("disabled", active || candidate, actor: actor)
      @environment.update!(state: "revoked", active_revision: nil, active_runtime_image: nil,
                           active_activation: nil, candidate_revision: nil, candidate_runtime_image: nil,
                           last_error_code: "coworker_disabled", last_audit_event: event)
    end
  end

  def prepare_removal!(actor: "system")
    @environment.revisions.includes(:runtime_image).find_each do |revision|
      image = revision.runtime_image
      next unless image && !image.deleted?

      begin
        Syrus::Host::RuntimeImages.retain(image, reason: "coworker environment audit history", actor: actor)
        audit("owner_removed", revision, actor: actor)
      rescue StandardError => e
        Rails.logger.warn("[Coworkers::EnvironmentLifecycle] could not retain revision #{revision.id}: " \
                          "#{e.class}: #{e.message}")
      end
    end
  end

  private

  def already_published?(revision, image)
    activation = @environment.active_activation
    revision.active? && image && @environment.active_revision_id == revision.id &&
      @environment.active_runtime_image_id == image.id && activation&.environment_revision_id == revision.id &&
      activation.runtime_image_id == image.id && activation.image_digest == image.digest
  end

  def terminate_affected_turns!(revision, reason:)
    digest = revision.runtime_image&.digest
    chat_ids = Coworkers::Chat.where(coworker_id: @environment.coworker_id).pluck(:chat_session_id)
    count = Syrus::Host::AgentRuntime.terminate_chat_processes(chat_session_ids: chat_ids,
                                                               reason: "severe environment revocation: #{reason}",
                                                               runtime_image_digest: digest)
    audit("turns_terminated", revision, code: "#{reason}:#{count}")
  end

  def current_attestation!(revision)
    attestation = Coworkers::EnvironmentVerificationEvidence.current(revision, now: @now)
    return attestation if attestation

    raise Coworkers::EnvironmentRevision::InvalidTransition, "candidate has no current accepted verification attestation"
  end

  def begin_verification!(revision)
    revision.transition_to!(:verifying) if revision.building?
  end

  def accept_candidate!(revision, result)
    image = result&.runtime_image
    return reject!(revision, code: "missing_image_record") unless image
    revision.update!(runtime_image: image) unless revision.runtime_image_id == image.id
    return revoke_locked!(revision, reason: "image_#{image.availability}") if image.revoked? || image.deleted?

    begin_verification!(revision)
    unless compatible_now?(revision)
      mark_incompatible!(revision)
      return
    end

    revision.transition_to!(:candidate, runtime_image: image) if revision.verifying?
    event = audit("verified", revision)
    revision.update!(audit_event: event) if event
    @environment.transition_to!(:candidate, candidate_revision: revision, candidate_runtime_image: image,
                                last_error_code: nil, last_audit_event: event) unless @environment.candidate?
    publish_event("candidate", revision)
  end

  def fail_build!(revision, code)
    transition_revision!(revision, revision.verifying? ? :rejected : :build_failed)
    clear_candidate!(revision, state: :failed, code: code, event: audit("build_failed", revision, code: code))
    publish_event("build_failed", revision)
  end

  def mark_incompatible!(revision)
    was_active = @environment.active_revision_id == revision.id
    transition_revision!(revision, revision.active? ? :retired : :rejected)
    clear_candidate!(revision, state: :failed, code: INCOMPATIBLE,
                     event: audit("incompatible", revision, code: INCOMPATIBLE), clear_active: was_active)
    publish_event("rejected", revision)
  end

  def compatible_now?(revision)
    base = Syrus::Host::RuntimeImages.active_base(platform: revision.runtime_image&.platform || "linux/amd64")
    base && revision.compatible_with?(base.runtime_abi)
  end

  def transition_revision!(revision, target)
    revision.transition_to!(target) if Coworkers::EnvironmentRevision::TRANSITIONS.fetch(revision.state, []).include?(target.to_s)
  end

  def revoke_locked!(revision, reason:, actor: "system", severity: "standard")
    revision.reload
    projected_current = revision.building? || revision.verifying? ||
      @environment.active_revision_id == revision.id || @environment.candidate_revision_id == revision.id
    image = revision.runtime_image
    Syrus::Host::RuntimeImages.revoke(image, reason: reason, actor: actor, severity: severity) if image&.available?
    target = revision.building? ? :build_failed : (revision.verifying? ? :rejected : :revoked)
    transition_revision!(revision, target)
    event = audit("revoked", revision, actor: actor, code: reason)
    attrs = { last_error_code: reason.to_s, last_audit_event: event }
    active_remains = @environment.active_revision_id.present? && @environment.active_revision_id != revision.id
    attrs[:state] = active_remains ? "active" : "revoked" if projected_current
    attrs.merge!(active_revision: nil, active_runtime_image: nil, active_activation: nil) if @environment.active_revision_id == revision.id
    attrs.merge!(candidate_revision: nil, candidate_runtime_image: nil) if @environment.candidate_revision_id == revision.id
    @environment.update!(attrs)
    publish_event("revoked", revision)
    revision
  end

  def clear_candidate!(revision, state:, code:, event:, clear_active: false)
    active_remains = @environment.active_revision_id.present? && !clear_active
    attrs = { state: active_remains ? "active" : state.to_s, last_error_code: code, last_audit_event: event }
    attrs.merge!(active_revision: nil, active_runtime_image: nil, active_activation: nil) if clear_active
    if @environment.candidate_revision_id == revision.id || @environment.candidate_revision_id.nil?
      attrs.merge!(candidate_revision: nil, candidate_runtime_image: nil)
    end
    @environment.update!(attrs)
  end

  def publish_event(kind, revision)
    inspection = Coworkers::EnvironmentInspection.new(@environment).call
    Syrus::Events.publish(
      "coworker_environment.#{kind}", coworker_id: @environment.coworker_id,
      environment_id: @environment.id, revision_id: revision&.id,
      inspection: Coworkers::EnvironmentInspectionSerializer.new(inspection).as_json
    )
  end

  def audit(action, revision, actor: "system", code: nil)
    image = revision&.runtime_image
    Syrus::Host::RuntimeImages.audit(
      "coworker_environment.#{action}", outcome: :ok, image: image, actor: actor,
      details: { coworker_id: @environment.coworker_id, environment_id: @environment.id,
                 revision_id: revision&.id, revision_number: revision&.number, code: code }.compact
    )
  end
end
