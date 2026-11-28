module Invariants
  # A deterministic failure must not be retried as if it were transient.
  #
  # The same Job failing the same step kind with the same failure fingerprint
  # more than `max_failures` times inside `window` is a retry storm: every
  # retry spends a worker and a provider session to learn nothing new. The
  # usual cause is a classification that calls a deterministic error
  # transient -- a native-gem build failure in a prepare step once failed
  # twenty times an hour classified as provider_transient.
  #
  # The fingerprint is Runs::FailureFingerprint -- the one
  # Runs::RepeatedFailure stops retrying on -- so the policy and this check
  # agree on what "the same failure" means. The classification is not part of
  # it (the classifier can label one error differently from run to run); it is
  # reported instead, as a tally.
  #
  # An external outage (every failure classified as one of
  # AutoRetryAttempt::OUTAGE_CLASSIFICATIONS) repeats identically by nature
  # and is retried on a time-based backoff, so failing more than
  # `max_failures` times is not a storm by itself. It still is one when it
  # passes either bound the policy keeps: more than `outage_max_failures` in
  # the window (above the most the in-place reruns and the capped ladder can
  # produce), or identical failures still arriving after `outage_horizon`
  # (past the policy's OUTAGE_RETRY_HORIZON plus a final attempt's reruns) --
  # a retry loop that never ends.
  class RetryStorms < Base
    DEFAULTS = { max_failures: 5, window: 1.hour, outage_max_failures: 30, outage_horizon: 2.hours }.freeze
    SAMPLE_RUN_IDS = 10
    MESSAGE_PREFIX = Runs::FailureFingerprint::MESSAGE_PREFIX

    def violations
      rows = failed_runs
      return [] if rows.empty?

      run_ids = rows.map(&:first)
      classifications = RunFailureClassification.where(run_id: run_ids).pluck(:run_id, :classification, :retryable).to_h { |id, *rest| [ id, rest ] }
      diagnostics = RunDiagnostic.where(run_id: run_ids).pluck(:run_id, :error_class, :error_message, :problem_code).to_h { |id, *rest| [ id, rest ] }

      groups = rows.group_by do |run_id, job_id, step_kind, _finished_at|
        [ job_id, step_kind, fingerprint_for(classifications[run_id], diagnostics[run_id]) ]
      end

      storms = groups.select do |key, group|
        next false unless group.size > options.fetch(:max_failures)
        next true unless outage_group?(group, classifications)

        group.size > options.fetch(:outage_max_failures) || outlasted_outage_horizon?(key)
      end
      return [] if storms.empty?

      jobs = Job.where(id: storms.keys.map(&:first)).index_by(&:id)
      storms.filter_map do |(job_id, step_kind, fingerprint), group|
        job = jobs[job_id]
        next unless job

        ordered = group.sort_by { |_, _, _, finished_at| finished_at }
        verdicts = ordered.map { |run_id, *| classifications[run_id] || [ nil, nil ] }
        tally = verdicts.map { |classification, _| classification || "unclassified" }.tally
        classification = tally.max_by { |name, count| [ count, name ] }.first
        error_class, error_message, problem_code = diagnostics[ordered.last.first]
        # Critical while any attempt was judged retryable: that is the
        # mislabel that keeps the storm going.
        violation(
          severity: verdicts.all? { |_, retryable| retryable == false } ? :warning : :critical,
          subject_type: "Job",
          subject_id: job.id,
          discriminator: "#{step_kind}:#{fingerprint}",
          since: ordered.first.last,
          message_params: { job: job.slug, step: step_kind, count: group.size, window_minutes: (options.fetch(:window) / 1.minute).round,
                            classification: classification },
          affected_ids: { job_ids: [ job.id ], run_ids: ordered.last(SAMPLE_RUN_IDS).map(&:first) },
          details: {
            job: job_ref(job),
            step_kind: step_kind,
            failures: group.size,
            max_failures: options.fetch(:max_failures),
            window_seconds: options.fetch(:window).to_i,
            first_failure_at: iso(ordered.first.last),
            last_failure_at: iso(ordered.last.last),
            fingerprint: fingerprint,
            classification: classification,
            classifications: tally,
            retryable: verdicts.any? { |_, retryable| retryable != false },
            problem_code: problem_code,
            error_class: error_class,
            error_message: error_message.to_s.squish.truncate(MESSAGE_PREFIX),
            recent_run_ids: ordered.last(SAMPLE_RUN_IDS).map(&:first)
          }
        )
      end
    end

    private

    def failed_runs
      relation = Run.joins(:step)
                    .where(state: "failed", finished_at: (now - options.fetch(:window))..now)
      scope.restrict(relation, :job_id).pluck("runs.id", "runs.job_id", "steps.kind", "runs.finished_at")
    end

    def outage_group?(group, classifications)
      group.all? { |run_id, *| AutoRetryAttempt.outage_classification?(classifications[run_id]&.first) }
    end

    # An identical failure of the same Job and step that finished a whole
    # `outage_horizon` before one inside the window: the loop outlived the
    # policy's horizon. Looks back one window past the horizon.
    def outlasted_outage_horizon?((job_id, step_kind, fingerprint))
      horizon = options.fetch(:outage_horizon)
      earlier = Run.joins(:step)
                   .where(job_id: job_id, state: "failed", steps: { kind: step_kind },
                          finished_at: (now - horizon - options.fetch(:window))..(now - horizon))
                   .pluck(:id)
      return false if earlier.empty?

      classifications = RunFailureClassification.where(run_id: earlier).pluck(:run_id, :classification).to_h
      diagnostics = RunDiagnostic.where(run_id: earlier).pluck(:run_id, :error_class, :error_message, :problem_code).to_h { |id, *rest| [ id, rest ] }
      earlier.any? { |run_id| fingerprint_for([ classifications[run_id] ], diagnostics[run_id]) == fingerprint }
    end

    def fingerprint_for(classification_row, diagnostic_row)
      classification, = classification_row
      error_class, error_message, problem_code = diagnostic_row
      Runs::FailureFingerprint.digest(classification: classification, error_class: error_class,
                                      error_message: error_message, problem_code: problem_code)
    end
  end
end
