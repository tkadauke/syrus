module Coworkers
  # Resolves the complete execution image tuple once, at turn admission. The
  # returned value is immutable and is also the payload persisted for retries.
  class TurnEnvironmentSelection
    Unavailable = Class.new(StandardError)
    Selection = Data.define(:kind, :feature_gate_enabled, :activation_id, :revision_id,
                            :base_release_id, :runtime_image_id, :image_digest, :base_digest,
                            :runtime_abi, :revocation_state, :runtime_image)

    def self.resolve(coworker:, user_message:)
      new(coworker:, user_message:).resolve
    end

    def initialize(coworker:, user_message:)
      @coworker = coworker
      @user_message = user_message
    end

    def resolve
      binding = Coworkers::TurnEnvironmentBinding.find_by(user_message_id: user_message.id)
      return selection_from_binding(binding) if binding

      gate_enabled = Feature.coworker_custom_environments_enabled?
      base_launch = Syrus::Host::RuntimeImages.base_launch
      unavailable!(base_launch.message || base_launch.code) unless base_launch.ready?

      if gate_enabled && coworker.environment&.active_activation
        custom_selection(base_launch, gate_enabled:)
      else
        standard_selection(base_launch, gate_enabled:)
      end
    rescue Coworkers::EnvironmentActiveSelection::InconsistentPointer => error
      unavailable!(error.message)
    end

    def persist!(chat_session:)
      attributes = {
        chat_session:, user_message:, coworker:, feature_gate_enabled: selection.feature_gate_enabled,
        selection_kind: selection.kind, environment_activation_id: selection.activation_id,
        environment_revision_id: selection.revision_id, coworker_base_release_id: selection.base_release_id,
        runtime_image_id: selection.runtime_image_id, image_digest: selection.image_digest,
        base_digest: selection.base_digest, runtime_abi: selection.runtime_abi,
        revocation_state: selection.revocation_state
      }
      Coworkers::TurnEnvironmentBinding.create!(attributes)
    rescue ActiveRecord::RecordNotUnique
      existing = Coworkers::TurnEnvironmentBinding.find_by!(user_message_id: user_message.id)
      unavailable!("the turn was already pinned to a different image") unless existing.image_digest == selection.image_digest
      existing
    end

    attr_reader :selection

    private

    attr_reader :coworker, :user_message

    def custom_selection(base_launch, gate_enabled:)
      active = Coworkers::EnvironmentActiveSelection.resolve(coworker.environment)
      return standard_selection(base_launch, gate_enabled:) unless active

      revision = Coworkers::EnvironmentRevision.includes(:base_release).find(active.revision_id)
      unavailable!("the active environment revision is no longer active") unless revision.active?
      unavailable!("the active environment base has been revoked or expired") unless revision.base_release&.supported?
      unless Syrus::Host::RuntimeImages.current_launch_contract?(active.runtime_image,
        provider: user_message.chat_session.effective_chat_provider)
        unavailable!("the active environment provider contract is incompatible")
      end
      unless revision.compatible_with?(base_launch.base.runtime_abi)
        unavailable!("the active environment is incompatible with runtime ABI #{base_launch.base.runtime_abi}")
      end

      @selection = Selection.new(
        kind: "custom", feature_gate_enabled: gate_enabled, activation_id: active.activation_id,
        revision_id: revision.id, base_release_id: revision.base_release.id,
        runtime_image_id: active.runtime_image_id, image_digest: active.image_digest,
        base_digest: revision.base_release.digest, runtime_abi: revision.runtime_abi,
        revocation_state: active.runtime_image.availability, runtime_image: active.runtime_image
      )
    end

    def standard_selection(base_launch, gate_enabled:)
      base = base_launch.base
      image = base_launch.runtime_image
      @selection = Selection.new(
        kind: "standard", feature_gate_enabled: gate_enabled, activation_id: nil, revision_id: nil,
        base_release_id: base.id, runtime_image_id: image.id, image_digest: image.digest,
        base_digest: base.digest, runtime_abi: base.runtime_abi,
        revocation_state: image.availability, runtime_image: image
      )
    end

    def selection_from_binding(binding)
      unavailable!("the pinned image has been revoked") unless binding.runtime_image.pullable?
      unavailable!("the pinned base has been revoked or expired") unless binding.base_release.supported?

      @selection = Selection.new(
        kind: binding.selection_kind, feature_gate_enabled: binding.feature_gate_enabled,
        activation_id: binding.environment_activation_id, revision_id: binding.environment_revision_id,
        base_release_id: binding.coworker_base_release_id, runtime_image_id: binding.runtime_image_id,
        image_digest: binding.image_digest, base_digest: binding.base_digest, runtime_abi: binding.runtime_abi,
        revocation_state: binding.runtime_image.availability, runtime_image: binding.runtime_image
      )
    end

    def unavailable!(reason)
      raise Unavailable, reason.to_s
    end
  end
end
