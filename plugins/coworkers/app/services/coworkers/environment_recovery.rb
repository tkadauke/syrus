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

    def rollback!(failed_activation:, actor:, target_revision: nil)
      environment.with_lock do
        failed_activation.reload
        unless environment.active_activation_id == failed_activation.id
          current = environment.active_activation
          audit("rollback_replayed", current, code: "active_pointer_advanced") if current
          return current
        end

        target = rollback_target(failed_activation)
        raise EnvironmentRevision::InvalidTransition, "no compatible verified rollback image is available" unless target
        if target_revision && target.environment_revision_id != target_revision.id
          raise EnvironmentRevision::InvalidTransition, "requested revision is not the next eligible rollback target"
        end

        activate!(target, failed_activation:, actor:)
      end
    end

    def refresh_retention!(actor: "system")
      keep = activation_chain(environment.active_activation)
        .select { |activation| launchable?(activation) }.first(rollback_retention_count + 1)
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
      activation_chain(failed_activation.previous_activation).detect { |activation| launchable?(activation) }
    end

    def activation_chain(first)
      Enumerator.produce(first) { |activation| activation&.previous_activation }.take_while(&:present?)
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
      target.runtime_image.lock!
      target.verification_attestation.lock!
      unless launchable?(target)
        raise EnvironmentRevision::InvalidTransition, "no compatible verified rollback image is available"
      end
      failed_activation.revision.transition_to!(:retired) if failed_activation.revision.active?
      target.revision.transition_to!(:active) if target.revision.retired?
      activation = environment.activations.create!(
        revision: target.revision, runtime_image: target.runtime_image,
        previous_activation: target.previous_activation,
        verification_attestation: target.verification_attestation,
        authority_lease: target.authority_lease,
        inherited_from_activation: target.authority_kind == "inherited" ? target.inherited_from_activation : nil,
        source_digest: target.source_digest, image_digest: target.image_digest,
        authority_kind: target.authority_kind, actor: actor.to_s, activated_at: now
      )
      event = audit("rolled_back", activation, code: "launch_failure_threshold")
      environment.update!(state: "active", active_revision: target.revision,
                          active_runtime_image: target.runtime_image, active_activation: activation,
                          last_error_code: nil, last_audit_event: event)
      refresh_retention!(actor:)
      inspection = EnvironmentInspectionSerializer.new(EnvironmentInspection.new(environment).call).as_json
      Syrus::Events.publish("coworker_environment.rolled_back", coworker_id: environment.coworker_id,
        environment_id: environment.id, revision_id: target.environment_revision_id, inspection:)
      activation
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
