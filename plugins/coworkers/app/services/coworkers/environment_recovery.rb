module Coworkers
  # Owns launch-failure recovery and bounded rollback retention. A prior
  # activation is already publication-authorized evidence for the exact digest,
  # so automatic rollback needs no broader or fresh publication authority.
  class EnvironmentRecovery
    RETENTION_REASON = "coworker environment rollback".freeze

    def initialize(environment, now: Time.current)
      @environment = environment
      @now = now
    end

    def record_launch_failure!(activation_id, reason:)
      environment.with_lock do
        activation = environment.activations.find(activation_id)
        return activation unless environment.active_activation_id == activation.id

        activation.increment!(:launch_failure_count)
        activation.update!(last_launch_failed_at: now)
        audit("launch_failed", activation, code: reason)
        if activation.launch_failure_count >= launch_failure_threshold
          target = rollback_target(activation)
          activate!(target, failed_activation: activation, actor: "automatic_launch_recovery") if target
        end
        activation
      end
    end

    def rollback!(failed_activation:, actor:)
      environment.with_lock do
        failed_activation.reload
        raise EnvironmentRevision::InvalidTransition, "rollback target is no longer active" unless environment.active_activation_id == failed_activation.id

        target = rollback_target(failed_activation)
        raise EnvironmentRevision::InvalidTransition, "no compatible verified rollback image is available" unless target

        activate!(target, failed_activation:, actor:)
      end
    end

    def refresh_retention!(actor: "system")
      keep = environment.activations.reorder(activated_at: :desc, id: :desc)
        .includes(:runtime_image).filter { |activation| launchable?(activation) }
        .first(rollback_retention_count + 1)
      keep_ids = keep.map(&:runtime_image_id)

      keep.each { |activation| Syrus::Host::RuntimeImages.retain(activation.runtime_image, reason: RETENTION_REASON, actor:) }
      environment.revisions.includes(:runtime_image).where.not(runtime_image_id: keep_ids).find_each do |revision|
        image = revision.runtime_image
        image.release_retention! if image&.retention_reason == RETENTION_REASON
      end
      keep
    end

    private

    attr_reader :environment, :now

    def launch_failure_threshold
      AppSetting.current.coworker_environment_launch_failure_threshold || 3
    end

    def rollback_retention_count
      AppSetting.current.coworker_environment_rollback_retention_count || 2
    end

    def rollback_target(failed_activation)
      environment.activations.where.not(id: failed_activation.id).reorder(activated_at: :desc, id: :desc)
        .includes(:revision, :runtime_image, :verification_attestation).detect { |activation| launchable?(activation) }
    end

    def launchable?(activation)
      activation.runtime_image.pullable? &&
        activation.verification_attestation.valid_at?(now) && compatible_with_active_base?(activation.revision)
    end

    def compatible_with_active_base?(revision)
      base = Syrus::Host::RuntimeImages.active_base(platform: revision.runtime_image.platform)
      base && revision.compatible_with?(base.runtime_abi)
    end

    def activate!(target, failed_activation:, actor:)
      failed_activation.revision.transition_to!(:retired) if failed_activation.revision.active?
      target.revision.transition_to!(:active) if target.revision.retired?
      event = audit("rolled_back", target, code: "launch_failure_threshold")
      environment.update!(state: "active", active_revision: target.revision,
                          active_runtime_image: target.runtime_image, active_activation: target,
                          last_error_code: nil, last_audit_event: event)
      refresh_retention!(actor:)
      target
    end

    def audit(action, activation, code: nil)
      Syrus::Host::RuntimeImages.audit(
        "coworker_environment.#{action}", outcome: :ok, image: activation.runtime_image,
        actor: "system", details: { coworker_id: environment.coworker_id,
                                    environment_id: environment.id, activation_id: activation.id,
                                    revision_id: activation.environment_revision_id, code: }.compact
      )
    end
  end
end
