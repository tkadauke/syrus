module Runs
  # A failure that comes back with the same fingerprint is evidence against
  # the "transient" label that is getting it retried.
  #
  # Two automatic loops retry a retryable failure: the dispatcher reruns the
  # Step in place (StepDispatcher#retry_step_after_infrastructure_failure!,
  # up to INFRASTRUCTURE_STEP_RETRY_LIMIT reruns) and the reconciler retries
  # the Workflow (the AutoRetryAttempt ladder, MAX_ATTEMPTS per
  # classification). Budgeted separately they multiply: a deterministic
  # timeout ran three times per attempt across four attempts -- twelve
  # identical failures before anything stopped.
  #
  # This is the one budget both loops share, per (Job, step kind,
  # fingerprint):
  #
  # * the in-place rerun stops as soon as a rerun fails exactly like the run
  #   before it -- the next remediation is a fresh Workflow (a fresh workspace
  #   and, usually, a fresh worker), not a third identical rerun;
  # * neither loop retries once the Job has failed that step with that
  #   fingerprint MAX_IDENTICAL_FAILURES times since its latest reopen. The
  #   reconciler then names the hold (operator_review_retry_budget_exhausted).
  #
  # Classifications whose remedy already changes the conditions are exempt:
  # a lost worker or an unprovisioned one is retried elsewhere, a rate limit or
  # usage limit waits for the provider's reset, a lost workspace is rebuilt.
  # Each has its own budget. So is an external outage
  # (AutoRetryAttempt::OUTAGE_CLASSIFICATIONS): an outage repeats identically
  # by nature, so it is bounded by how long it has lasted instead
  # (outage_retry_window_open?), never ended at an operator hold for
  # outlasting five minutes.
  module RepeatedFailure
    # Below the retry_storms invariant's default `max_failures` (5), so a
    # deterministic failure stops before it becomes a storm.
    MAX_IDENTICAL_FAILURES = 4

    EXEMPT_CLASSIFICATIONS = (
      AutoRetryAttempt::IN_PLACE_STEP_CLASSIFICATIONS +
      AutoRetryAttempt::OUTAGE_CLASSIFICATIONS +
      [ "rate_limited", ProviderUsageLimit::CLASSIFICATION, "workspace_recovery_failed" ]
    ).freeze

    module_function

    def exempt?(run)
      classification_of(run).in?(EXEMPT_CLASSIFICATIONS)
    end

    def outage?(run)
      AutoRetryAttempt.outage_classification?(classification_of(run))
    end

    # The ladder's bound for an outage: retry while the outage has lasted less
    # than OUTAGE_RETRY_HORIZON, measured by its failures -- from the first of
    # this Job's identical failures of the step since its latest reopen to this
    # one. Measured against the failures rather than the clock, so a failure the
    # reconciler only finds late (masked by terminal cleanup, say) still gets
    # its retry. Always open for anything else.
    def outage_retry_window_open?(run, now: Time.current)
      return true unless run&.failed? && run.step && outage?(run)

      started_at = outage_started_at(run)
      started_at.nil? || started_at > (run.finished_at || now) - AutoRetryAttempt::OUTAGE_RETRY_HORIZON
    end

    def outage_started_at(run)
      identical_failure_ids(run).then { |ids| Run.where(id: ids).minimum(:finished_at) }
    end

    def classification_of(run)
      run.run_failure_classification&.classification.presence || run.agent_outcome.to_s
    end

    # The dispatcher's in-place rerun: stop once a rerun repeated the failure
    # of the Run before it, or the shared budget is spent.
    def stop_in_place?(run)
      return false unless run&.failed? && run.step
      return false if exempt?(run)

      repeats_previous_run?(run) || budget_exhausted?(run)
    end

    # The reconciler's auto-retry ladder.
    def budget_exhausted?(run)
      return false unless run&.failed? && run.step
      return false if exempt?(run)

      identical_failures(run) >= MAX_IDENTICAL_FAILURES
    end

    def repeats_previous_run?(run)
      previous = run.step.runs.where(state: "failed").where("runs.id < ?", run.id).reorder(id: :desc).first
      return false unless previous

      fingerprints = FailureFingerprint.for_run_ids([ run.id, previous.id ])
      fingerprints[run.id] == fingerprints[previous.id]
    end

    # Failed Runs of this Job and step kind, since the Job's latest reopen,
    # that failed with this Run's fingerprint (this Run included).
    def identical_failures(run)
      identical_failure_ids(run).size
    end

    def identical_failure_ids(run)
      job = run.job
      candidate_ids = Run.joins(:step)
                         .where(job_id: job.id, state: "failed", steps: { kind: run.step.kind })
                         .where(steps: { workflow_id: job.workflows_since_latest_reopen.select(:id) })
                         .pluck(:id)
      candidate_ids |= [ run.id ]
      fingerprints = FailureFingerprint.for_run_ids(candidate_ids)
      target = fingerprints[run.id]
      fingerprints.select { |_id, fingerprint| fingerprint == target }.keys
    end
  end
end
