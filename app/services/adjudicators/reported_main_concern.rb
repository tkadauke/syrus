module Adjudicators
  # `report_main_concern` alone is a claim, not evidence (workflow-engine-v3
  # rung-0 guardrail: "an adjudication never applies itself"). InheritedGraderFailure
  # already dismisses a grader failure once a repository's main-health
  # crowd-quorum has actually tripped (Repository#main_health_broken?) -- but
  # a single flaky/systemic required grader on an otherwise-healthy base
  # never reaches that threshold, so a Job stuck behind it (an external PR,
  # a landing attempt) has no deterministic path to relief short of burning
  # every repair iteration the grade loop allows.
  #
  # This adjudicator only dismisses when BOTH are true for this exact loop
  # iteration: an agent working the repair filed report_main_concern, AND a
  # live BaseRevisionRetry independently confirms every currently-failing
  # required grader also fails when rerun against the base revision. Neither
  # signal is authoritative alone -- an agent's word is not evidence, and a
  # base_retry result on a grader nobody flagged is InheritedGraderFailure's
  # business, not this one's. `failures: strict` graders are never eligible,
  # the same absolute floor InheritedGraderFailure respects.
  module ReportedMainConcern
    def self.adjudicate(problem:, workflow: nil, step: nil, base_sha: nil, **)
      return Adjudication.inconclusive(adjudicator: name) unless problem&.code == "grader_failure"
      return Adjudication.inconclusive(adjudicator: name) unless workflow

      steps = Array(step || TestEvidenceLookup.failed_grader_steps(workflow)).select { |candidate| candidate.respond_to?(:details) }
      return Adjudication.inconclusive(adjudicator: name) if steps.empty?
      return Adjudication.inconclusive(adjudicator: name, reason: "strict_failure_policy") unless steps.all? { |grader_step| allow_inherited?(grader_step) }
      return Adjudication.inconclusive(adjudicator: name, reason: "no_main_concern_reported") unless main_concern_reported_for_iteration?(workflow, steps)
      return Adjudication.inconclusive(adjudicator: name, reason: "no_base_sha") if base_sha.blank?

      results = steps.map { |grader_step| verify(workflow, grader_step, base_sha) }
      return Adjudication.inconclusive(adjudicator: name, reason: "base_retry_not_confirmed") unless results.all? { |result| result&.inherited }

      Adjudication.dismiss(
        adjudicator: name,
        reason: "main_concern_verified_by_base_retry",
        evidence: {
          base_sha: base_sha,
          grader_names: steps.map { |grader_step| grader_step.details.to_h["name"] },
          base_retry_results: results.map { |result| { command: result.command, reason: result.reason } }
        }
      )
    end

    def self.allow_inherited?(grader_step)
      grader_step.details.to_h["failures"].to_s == MainBranchFailureClassifier::ALLOW_INHERITED
    end

    # "This exact iteration" means the loop iteration the failing grader
    # Steps belong to -- the repair step that ran immediately before them
    # (whichever kind: landing_fix, implement, respond, analyze_and_fix, ...)
    # shares that same loop_id/iteration (StepDispatcher#enqueue_next_loop_iteration!
    # stamps repair and check steps with the same `next_iteration`). A
    # report filed for a different iteration, or for a different Job/PR
    # entirely, must not count here.
    def self.main_concern_reported_for_iteration?(workflow, steps)
      loop_id = steps.first.loop_id
      iteration = steps.first.iteration
      return false if loop_id.blank?

      run_ids = workflow.steps
        .where(loop_id: loop_id, iteration: iteration)
        .where.not(kind: %w[grader grader_fanout grader_collect format generate])
        .flat_map { |candidate| candidate.runs.pluck(:id) }
      return false if run_ids.empty?

      MainConcernReport.where(run_id: run_ids).exists?
    end

    def self.verify(workflow, grader_step, base_sha)
      candidate_run = grader_step.runs.order(:created_at).last
      grader_name = grader_step.details.to_h["name"].to_s
      BaseRevisionRetry.call(
        workflow: workflow,
        grader_step: grader_step,
        base_sha: base_sha,
        failed_cases: TestEvidenceLookup.failed_test_cases_for(candidate_run, grader_name),
        log: ->(message) { JobLog.append!(run: candidate_run, chunk: message, kind: "system") if candidate_run }
      )
    rescue StandardError => e
      Rails.logger.warn("[Adjudicators::ReportedMainConcern] base retry failed for grader step ##{grader_step.id}: #{e.class}: #{e.message}")
      nil
    end

    def self.name = "reported_main_concern"
  end
end
