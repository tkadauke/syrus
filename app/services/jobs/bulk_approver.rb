module Jobs
  # Approves a batch of Jobs with a row lock per Job and a definite
  # per-Job success/failure result, instead of a caller assuming every
  # Job in the batch actually transitioned. Job's AASM machine runs
  # with whiny_transitions: false, and an earlier eligibility filter
  # (may_approve?) can go stale by the time the transition actually
  # runs: a concurrent path — the PR poller's
  # `@job.approve!(via: "github_review")`, AutoApprovalRule, another
  # operator action — can flip the Job's state in the race window
  # between the filter and the call. Locking the row and re-checking
  # `may_approve?` right before transitioning closes that window;
  # reporting per-Job success/failure lets the caller exclude a Job
  # that lost the race instead of silently reporting it as approved.
  # Mirrors the lock-then-check pattern already used by
  # EpicLandingRetrier/JobBundleRetrier/LandingQueueProcessor.
  class BulkApprover
    Result = Data.define(:approved, :failed) do
      def success? = approved.any?
    end

    def self.call(jobs, via:, by_user: nil, evidence: {})
      new(jobs, via: via, by_user: by_user, evidence: evidence).call
    end

    def initialize(jobs, via:, by_user: nil, evidence: {})
      @jobs = jobs
      @via = via
      @by_user = by_user
      @evidence = evidence
    end

    def call
      approved = []
      failed = []

      Job.transaction do
        @jobs.each do |job|
          job.lock!

          unless job.may_approve?
            failed << job
            next
          end

          job.approve!(via: @via, by_user: @by_user, evidence: @evidence)
          approved << job
        end
      end

      Result.new(approved: approved, failed: failed)
    end
  end
end
