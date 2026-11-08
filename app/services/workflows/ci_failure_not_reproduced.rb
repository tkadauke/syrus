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

    def self.applies?(workflow)
      workflow.trigger_kind == "ci_failure" &&
        (workflow.job.pr_number.presence || workflow.job.external_pr_number.presence).present?
    end

    def self.call(workflow, grader_outcome: nil) = new(workflow, grader_outcome).call

    def initialize(workflow, grader_outcome)
      @workflow = workflow
      @job = workflow.job
      @grader_outcome = grader_outcome
    end

    def call
      head_sha = workflow.artifact("head_sha")
      prior = prior_count(head_sha)
      escalated = prior + 1 >= ESCALATION_THRESHOLD
      workflow.set_artifact!(ARTIFACT, record(head_sha, escalated))

      job.mark_implemented! if job.may_mark_implemented?
      attrs = { last_ci_handled_sha: head_sha }.compact
      attrs[:landing_failure_reason] = escalation_reason(head_sha, prior + 1) if escalated
      job.update!(attrs) if attrs.any?
      PollPullRequestJob.perform_later(job.id) unless escalated
    end

    private

    attr_reader :workflow, :job, :grader_outcome

    def failed_checks
      Array(workflow.artifact("failed_checks")).map { |check| check.to_h.stringify_keys }
    end

    def record(head_sha, escalated)
      outcome = grader_outcome.to_h.stringify_keys
      {
        "outcome" => OUTCOME,
        "check_names" => failed_checks.filter_map { |check| check["name"] },
        "head_sha" => head_sha,
        "reproduction_command" => outcome["command"],
        "evidence" => outcome["evidence"] || outcome["reason"] || "agent found no source change to make for the failed check",
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
