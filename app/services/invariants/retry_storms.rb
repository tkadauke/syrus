require "digest"

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
  # The fingerprint is the failure classification plus the recorded error
  # class and message with volatile tokens (numbers, hex ids, paths under the
  # data root) masked, so two failures that differ only in a run id or a
  # timestamp count as one failure repeated.
  class RetryStorms < Base
    DEFAULTS = { max_failures: 5, window: 1.hour }.freeze
    SAMPLE_RUN_IDS = 10
    MESSAGE_PREFIX = 300

    def violations
      rows = failed_runs
      return [] if rows.empty?

      run_ids = rows.map(&:first)
      classifications = RunFailureClassification.where(run_id: run_ids).pluck(:run_id, :classification, :retryable).to_h { |id, *rest| [ id, rest ] }
      diagnostics = RunDiagnostic.where(run_id: run_ids).pluck(:run_id, :error_class, :error_message, :problem_code).to_h { |id, *rest| [ id, rest ] }

      groups = rows.group_by do |run_id, job_id, step_kind, _finished_at|
        [ job_id, step_kind, fingerprint_for(classifications[run_id], diagnostics[run_id]) ]
      end

      storms = groups.select { |_key, group| group.size > options.fetch(:max_failures) }
      return [] if storms.empty?

      jobs = Job.where(id: storms.keys.map(&:first)).index_by(&:id)
      storms.filter_map do |(job_id, step_kind, fingerprint), group|
        job = jobs[job_id]
        next unless job

        ordered = group.sort_by { |_, _, _, finished_at| finished_at }
        sample_run_id = ordered.last.first
        classification, retryable = classifications[sample_run_id]
        error_class, error_message, problem_code = diagnostics[sample_run_id]
        violation(
          severity: retryable == false ? :warning : :critical,
          subject_type: "Job",
          subject_id: job.id,
          discriminator: "#{step_kind}:#{fingerprint}",
          since: ordered.first.last,
          message_params: { job: job.slug, step: step_kind, count: group.size, window_minutes: (options.fetch(:window) / 1.minute).round,
                            classification: classification || "unclassified" },
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
            retryable: retryable,
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

    def fingerprint_for(classification_row, diagnostic_row)
      classification, = classification_row
      error_class, error_message, problem_code = diagnostic_row
      normalized = error_message.to_s
                                .gsub(%r{/[^\s:'"]*/(?:workflows|runs|tmp)/[^\s:'"]*}, "<path>")
                                .gsub(/\b[0-9a-f]{7,40}\b/i, "<hex>")
                                .gsub(/\d+/, "<n>")
                                .squish
                                .first(MESSAGE_PREFIX)
      Digest::SHA256.hexdigest([ classification, problem_code, error_class, normalized ].join("\n")).first(16)
    end
  end
end
