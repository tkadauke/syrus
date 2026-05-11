module Workflows
  # Operator clicked "Retry" on a Job — start over on the same
  # branch as if it were Initial. Same shape as Initial; the
  # difference is per-step behavior: implement on a retry reuses
  # the existing branch instead of branching from default; pr_open
  # short-circuits if the Job already has a PR number.
  class Retry < Base
    steps :prepare, :implement, :summarize, :pr_open

    def self.trigger_kind = "retry"

    def self.steps_for(job)
      prepare_skipped_for?(job) ? %w[ implement summarize pr_open ] : step_kinds
    end

    def self.prepare_skipped_for?(job)
      job.skip_prepare?
    end
  end
end
