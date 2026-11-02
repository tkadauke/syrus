class JobDependency
  module SatisfactionModes
    class Landed < Base
      LANDED_CLOSURE_REASONS = %w[
        pr_merged
        external_pr_merged
        promotion_landed
        hotfix_sync_landed
        emergency_landed
      ].freeze

      def dependency_succeeded?
        return false unless dependency.depends_on_job

        job = dependency.depends_on_job
        return true if job.closed? && job.closure_reason == "no_changes"

        job.closed? && job.landed_sha.present? && LANDED_CLOSURE_REASONS.include?(job.closure_reason)
      end

      def validate!
        super
        return if dependency.depends_on_job_id.present?

        dependency.errors.add(:depends_on_job, "must be a Job for landed dependencies")
      end
    end
  end
end
