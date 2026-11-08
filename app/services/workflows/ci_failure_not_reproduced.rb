module Workflows
  # A `ci_failure` follow-up on an existing PR that produced no diff is a
  # diagnostic result (the failed check did not reproduce, or could not be
  # observed), not evidence that the Job's work is empty. This records an
  # explicit evidence-backed outcome on the Workflow, preserves the PR, returns
  # the Job to review, and schedules a SHA-bound PR check refresh instead of
  # manufacturing a source change.
  class CiFailureNotReproduced
    OUTCOME = "failure_not_reproduced".freeze
    ARTIFACT = "ci_failure_outcome".freeze
    ESCALATION_THRESHOLD = 2

    # A genuine reproducible test failure (a grader reported `test_failed`)
    # is not handled here; it continues through the normal repair policy.
    def self.applies?(workflow)
      workflow.trigger_kind == "ci_failure" &&
        (workflow.job.pr_number.presence || workflow.job.external_pr_number.presence).present? &&
        new(workflow).grader_results.none?(&:test_failed?)
    end

    def self.call(workflow) = new(workflow).call

    def initialize(workflow)
      @workflow = workflow
      @job = workflow.job
    end

    def call
      head_sha = workflow.artifact("head_sha")
      prior = prior_count(head_sha)
      escalated = prior + 1 >= ESCALATION_THRESHOLD
      workflow.set_artifact!(ARTIFACT, record(head_sha, escalated))

      # A Job already back in review (implemented/approved) keeps its state, and
      # therefore its approval; only a Job left :running is returned to review.
      job.mark_implemented! if job.running? && job.may_mark_implemented?
      attrs = {}
      attrs[:last_ci_handled_sha] = head_sha if head_sha.present?
      attrs[:landing_failure_reason] = escalation_reason(head_sha, prior + 1) if escalated
      # Expire the cached check state so the next poll re-reads this SHA's
      # checks. The handled-SHA watermark stays, so no new repair workflow (or
      # speculative commit) is started for it.
      attrs[:pr_checks_checked_at] = nil unless escalated
      job.update!(attrs) if attrs.any?
      PollPullRequestJob.perform_later(job.id) unless escalated
    end

    def grader_results
      @grader_results ||= workflow.steps.where(kind: "grader").map { |step| GraderOutcome.for_step(step) }
    end

    private

    attr_reader :workflow, :job

    def outcome_name
      results = grader_results
      return OUTCOME if results.any? && results.all?(&:passed?)
      return GraderOutcome::INFRASTRUCTURE_FAILED if results.any? { |r| r.outcome == GraderOutcome::INFRASTRUCTURE_FAILED }

      GraderOutcome::INCONCLUSIVE
    end

    def reproduction_evidence
      grader_results.map(&:evidence).find { |e| e["command"].present? } || {}
    end

    def agent_summary
      run = workflow.runs.where(state: "failed").reorder(created_at: :desc, id: :desc).first
      run&.agent_summary.presence || run&.run_diagnostic&.error_message
    end

    def failed_checks
      Array(workflow.artifact("failed_checks")).map { |check| check.to_h.stringify_keys }
    end

    def record(head_sha, escalated)
      evidence = reproduction_evidence
      {
        "outcome" => outcome_name,
        "grader_outcomes" => grader_results.map(&:to_h),
        "check_names" => failed_checks.filter_map { |check| check["name"] },
        "head_sha" => head_sha,
        "reproduction_command" => evidence["command"],
        "reproduction_sha" => evidence["source_sha"],
        "evidence" => agent_summary || "agent found no source change to make for the failed check",
        "recorded_at" => Time.current.iso8601,
        "pr_preserved" => true,
        "approval_restored" => false,
        "check_rerun" => escalated ? "escalated_to_operator" : "pr_check_refresh_scheduled",
        "escalated" => escalated
      }.compact
    end

    def prior_count(head_sha)
      job.workflows.where(trigger_kind: "ci_failure").where.not(id: workflow.id).count do |other|
        other.artifact(ARTIFACT).to_h["head_sha"] == head_sha && other.artifact("head_sha") == head_sha
      end
    end

    def escalation_reason(head_sha, count)
      "ci_failure_not_reproduced: #{job.slug} #{count} CI repair attempts for #{head_sha.to_s[0, 12]} " \
        "did not reproduce the failure; PR preserved, operator attention needed."
    end
  end
end
