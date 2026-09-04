module Decisions
  # Turns a terminally failed Workflow into a Decision (workflow-engine-v3 B2).
  #
  # This is rung 4 -- the human -- reached only after the cheaper rungs
  # declined. It is also the thing the escalations-per-landing metric counts,
  # so it deliberately files one Decision per distinct problem rather than per
  # occurrence: `Decisions::Opener` reuses an open decision for the same
  # signature and declines entirely when the same problem was already decided.
  #
  # Nothing here decides anything. It records that a person has to.
  class Escalator
    def self.call(...) = new(...).call

    def initialize(workflow:)
      @workflow = workflow
    end

    def call
      return nil unless @workflow.failed?

      problem = problem_for(failed_step)
      return nil unless problem

      Decisions::Opener.call(
        problem: problem,
        title: title_for(problem),
        summary: @workflow.failure_reason.presence,
        urgency: urgency_for,
        adjudication: recorded_adjudication,
        actions: actions_for,
        job: @workflow.job,
        workflow: @workflow,
        step: failed_step
      )
    end

    private

    def failed_step
      @failed_step ||= @workflow.steps.where(state: "failed").order(:position).last
    end

    # The failure in the shared vocabulary. A step's own `problem_code` wins
    # over the run classification, because the step knew what it was doing when
    # it failed; the classification is inference after the fact.
    def problem_for(step)
      evidence = { workflow_slug: @workflow.slug, step_kind: step&.kind }.compact

      from_step = step&.details.to_h["problem_code"]
      return Problem[from_step, evidence: evidence] if from_step.present? && Problem::Kind.exists?(from_step)

      classification = step&.latest_run&.run_failure_classification&.classification
      Problem.resolve(classification, evidence: evidence)
    end

    def title_for(problem)
      "#{problem.label} on #{@workflow.job&.slug || @workflow.slug}"
    end

    # A stalled landing is the expensive failure; a failed initial attempt is
    # normal and cheap.
    def urgency_for
      case @workflow.trigger_kind
      when "auto_merge", "merge_train", "main_branch_repair" then "urgent"
      when "initial", "retry" then "low"
      else "normal"
      end
    end

    def recorded_adjudication
      verdict = @workflow.artifact("rung_zero_adjudication")
      verdict.is_a?(Hash) ? verdict : nil
    end

    # The actions an operator already has for a failed workflow, attached to
    # the thing that needs deciding rather than hunted for on a Job page.
    def actions_for
      return [] unless @workflow.job

      [
        { "action_key" => "retry_job", "label" => "Retry from the failed step",
          "payload" => { "job_id" => @workflow.job_id } }
      ]
    end
  end
end
