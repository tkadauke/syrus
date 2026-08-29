module CiRepair
  class NonActionableDiagnosis
    ARTIFACT_KEY = "ci_failure_non_actionable_diagnosis".freeze
    OUTCOME = "blocked_by_main".freeze

    def self.detect(workflow:, run:)
      new(workflow: workflow, run: run).detect
    end

    def self.call(dispatcher:, workflow:, step:)
      new(workflow: workflow, run: step.latest_run).advance_from_step!(dispatcher: dispatcher, step: step)
    end

    def initialize(workflow:, run:)
      @workflow = workflow
      @run = run
    end

    def detect
      return unless workflow&.trigger_kind == "ci_failure"
      return unless run

      current_reports.each do |report|
        signature = signature_for(report)
        next unless complete_signature?(signature)

        if (prior = prior_report_for(signature))
          return artifact_for(report, prior, signature)
        end
      end

      nil
    end

    def advance_from_step!(dispatcher:, step:)
      return false unless workflow&.trigger_kind == "ci_failure"
      return false unless step.kind == "analyze_and_fix"

      diagnosis = workflow.artifact(ARTIFACT_KEY).to_h
      return false unless diagnosis["outcome"] == OUTCOME
      return false unless diagnosis["run_id"] == run&.id

      dispatcher.skip_current_retry_until_check_steps!(
        step: step,
        artifact_key: ARTIFACT_KEY,
        reason: OUTCOME
      )
    end

    private

    attr_reader :workflow, :run

    def current_reports
      @current_reports ||= MainConcernReport
        .where(workflow: workflow, run: run)
        .order(:created_at, :id)
        .to_a
    end

    def prior_report_for(signature)
      MainConcernReport
        .where(workflow: workflow)
        .where.not(run_id: run.id)
        .order(created_at: :desc, id: :desc)
        .detect { |report| signature_for(report) == signature }
    end

    def signature_for(report)
      {
        "observed_sha" => report.observed_sha.to_s.strip,
        "failing_tests" => Array(report.failing_tests).map { |test| test.to_s.strip }.reject(&:empty?).sort,
        "reason" => normalize_reason(report.reason)
      }
    end

    def complete_signature?(signature)
      signature["observed_sha"].present? &&
        signature["failing_tests"].present? &&
        signature["reason"].present?
    end

    def normalize_reason(reason)
      reason.to_s.downcase.squish
    end

    def artifact_for(report, prior, signature)
      {
        "outcome" => OUTCOME,
        "run_id" => run.id,
        "step_id" => run.step_id,
        "iteration" => run.iteration,
        "current_report_id" => report.id,
        "prior_report_id" => prior.id,
        "prior_run_id" => prior.run_id,
        "observed_sha" => signature["observed_sha"],
        "failing_tests" => signature["failing_tests"],
        "reason" => report.reason.to_s,
        "detected_at" => Time.current.iso8601
      }
    end
  end
end
