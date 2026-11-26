class Coworkers::EnvironmentLifecycle
  def candidate!(revision, image)
    transition!(revision, :candidate, runtime_image_id: image.id)
  end

  def verified!(revision)
    transition!(revision, :verified)
    revision.environment.update!(state: "candidate", candidate_revision: revision,
                                 candidate_runtime_image: revision.runtime_image, last_error_code: nil)
  end

  def reject!(revision, code: nil)
    transition!(revision, :rejected, code: code)
    clear_candidate(revision.environment, revision, state: "failed", code: code)
  end

  def build_failed!(revision, code: nil)
    transition!(revision, :build_failed, code: code)
    clear_candidate(revision.environment, revision, state: "failed", code: code)
  end

  def publish!(revision, actor: "system")
    raise Coworkers::EnvironmentBuildRequest::Disabled unless Feature.coworker_custom_environments_enabled?

    environment = revision.environment
    environment.with_lock do
      revision.reload
      raise Coworkers::EnvironmentRevision::InvalidTransition unless revision.verified? || revision.retired?
      raise Coworkers::EnvironmentRevision::InvalidTransition, "published revisions require a pullable image" unless revision.runtime_image&.pullable?

      previous = environment.active_revision
      transition!(previous, :retired, actor: actor) if previous && previous != revision && previous.published?
      transition!(revision, :published, actor: actor)
      environment.update!(state: "active", active_revision: revision, active_runtime_image: revision.runtime_image,
                          candidate_revision: nil, candidate_runtime_image: nil, last_error_code: nil)
    end
  end

  def retire!(revision, actor: "system")
    transition!(revision, :retired, actor: actor)
    clear_active(revision.environment, revision, state: "draft")
  end

  def revoke!(revision, reason:, actor: "system")
    image = revision.runtime_image
    Syrus::Host::RuntimeImages.revoke(image, reason: reason) if image && !image.revoked? && !image.deleted?
    transition!(revision, :revoked, code: reason, actor: actor)
    clear_pointers(revision.environment, revision, state: "revoked", code: reason)
  end

  def incompatible!(revision, reason: "runtime_abi_incompatible")
    transition!(revision, :incompatible, code: reason)
    clear_pointers(revision.environment, revision, state: "incompatible", code: reason)
  end

  def deleted!(revision, reason: "runtime_image_missing")
    transition!(revision, :deleted, code: reason)
    clear_pointers(revision.environment, revision, state: "deleted", code: reason)
  end

  def remove_coworker!(coworker)
    environment = coworker.environment
    return unless environment

    environment.with_lock do
      environment.revisions.where(state: %w[published verified candidate]).find_each do |revision|
        target = revision.published? || revision.verified? ? :retired : :rejected
        transition!(revision, target, actor: "coworker_removed")
      end
      environment.update!(state: "deleted", active_revision: nil, candidate_revision: nil,
                          active_runtime_image: nil, candidate_runtime_image: nil, last_error_code: "coworker_removed")
      audit(environment, nil, "environment.coworker_removed", actor: "system")
    end
  end

  def disable_coworker!(coworker)
    environment = coworker.environment
    return unless environment

    environment.with_lock do
      environment.revisions.where(state: %w[published verified candidate]).find_each do |revision|
        target = revision.candidate? ? :rejected : :retired
        transition!(revision, target, actor: "coworker_disabled")
      end
      environment.update!(state: "draft", active_revision: nil, candidate_revision: nil,
                          active_runtime_image: nil, candidate_runtime_image: nil,
                          last_error_code: "coworker_disabled")
      audit(environment, nil, "environment.coworker_disabled", actor: "system")
    end
  end

  private

  def transition!(revision, state, code: nil, actor: "system", **attributes)
    return revision if revision.nil? || revision.state == state.to_s

    revision.transition_to!(state, **attributes)
    event = audit(revision.environment, revision, "environment.#{state}", actor: actor, code: code)
    revision.update_column(:audit_event_id, event.id) if event
    revision
  end

  def clear_candidate(environment, revision, state:, code: nil)
    environment.reload
    attributes = { state: state, last_error_code: code }
    attributes.merge!(candidate_revision: nil, candidate_runtime_image: nil) if environment.candidate_revision_id == revision.id
    environment.update!(attributes)
  end

  def clear_active(environment, revision, state:)
    environment.reload
    return unless environment.active_revision_id == revision.id
    environment.update!(state: state, active_revision: nil, active_runtime_image: nil)
  end

  def clear_pointers(environment, revision, state:, code: nil)
    environment.reload
    attributes = { state: state, last_error_code: code }
    attributes.merge!(active_revision: nil, active_runtime_image: nil) if environment.active_revision_id == revision.id
    attributes.merge!(candidate_revision: nil, candidate_runtime_image: nil) if environment.candidate_revision_id == revision.id
    environment.update!(attributes)
  end

  def audit(environment, revision, event_type, actor:, code: nil)
    event = Syrus::Host::RuntimeImages.audit(event_type, outcome: :ok, image: revision&.runtime_image, actor: actor,
                                             details: { coworker_environment_id: environment.id,
                                                        revision_id: revision&.id, code: code }.compact)
    environment.update_column(:last_audit_event_id, event.id) if event
    event
  end
end
