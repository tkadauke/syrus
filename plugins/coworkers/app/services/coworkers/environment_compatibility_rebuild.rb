module Coworkers
  # Requests a replacement from an active revision's immutable source. The
  # active pointer is deliberately untouched until the replacement has passed
  # verification and publication authority is evaluated.
  class EnvironmentCompatibilityRebuild
    def initialize(runtime_image_id:, replacement_base_release_id:, reasons:)
      @runtime_image_id = runtime_image_id
      @replacement_base_release_id = replacement_base_release_id
      @reasons = Array(reasons).map(&:to_s)
    end

    def call
      return unless Feature.coworker_custom_environments_enabled?

      environment = Environment.find_by(active_runtime_image_id: runtime_image_id)
      return unless environment

      active = environment.active_revision
      replacement = Syrus::Host::RuntimeImages.base_for_rebuild(replacement_base_release_id)
      return unless active&.active? && replacement

      revision = nil
      environment.with_lock do
        environment.reload(lock: true)
        active = environment.active_revision
        return unless active&.active? && active.runtime_image_id == runtime_image_id

        revision = existing_replacement(environment, active, replacement) || environment.revisions.create!(
          number: environment.next_revision_number,
          state: "draft",
          source_digest: active.source_digest,
          source_manifest: active.source_manifest,
          created_by_user: active.created_by_user
        )
      end

      EnvironmentBuildRequest.new(environment.coworker, nil).call_revision(
        revision, base: replacement, reason: "compatibility rebuild: #{reasons.join(', ')}"
      )
    end

    private

    attr_reader :runtime_image_id, :replacement_base_release_id, :reasons

    def existing_replacement(environment, active, replacement)
      environment.revisions.where(source_digest: active.source_digest).where(
        "(coworker_base_release_id = ? AND state IN (?)) OR " \
        "(coworker_base_release_id IS NULL AND state = ? AND number > ?)",
        replacement.id, %w[building verifying candidate active], "draft", active.number
      ).last
    end
  end
end
