class RecoveryDecision
  Decision = Data.define(:kind, :recommended_action, :mode, :explanation, :guidance, :evidence) do
    def as_json(*)
      { kind:, recommended_action:, mode:, explanation:, guidance:, evidence: }.compact
    end
  end

  POLICIES = %w[
    RecoveryDecision::Policies::NoProgress
    RecoveryDecision::Policies::WorkspaceUnavailable
    RecoveryDecision::Policies::InfrastructureOnly
    RecoveryDecision::Policies::InterruptedResumable
    RecoveryDecision::Policies::MeasuredFailure
    RecoveryDecision::Policies::RestartFromBase
  ].freeze

  def self.for(job:, workflow: nil)
    workflow ||= job.workflows.where(state: %w[failed blocked cancelled]).reorder(created_at: :desc, id: :desc).first
    context = Context.new(job, workflow)
    POLICIES.lazy.map(&:constantize).map { |policy| policy.new(context) }.find(&:match?).decision
  end

  class Context
    attr_reader :job, :workflow

    def initialize(job, workflow)
      @job = job
      @workflow = workflow
    end

    def failed_step = workflow && RetryFailedStepEnqueuer.failed_step_for(workflow)
    def failed_run = failed_step&.latest_run
    def classification = failed_run&.run_failure_classification&.classification.to_s.presence
    def stop = workflow&.artifact(GraderLoopProgress::STOP_ARTIFACT_KEY).to_h
    def retry_available? = workflow&.retry_available? == true
    def revision = failed_run&.head_sha.presence || workflow&.artifact("head_sha").presence

    def evidence
      {
        source_workflow_id: workflow&.id,
        source_loop_id: failed_step&.loop_id,
        source_step_id: failed_step&.id,
        source_run_id: failed_run&.id,
        source_revision: revision,
        failure_classification: classification
      }.compact
    end
  end

  module Policies
    class Base
      def initialize(context) = @context = context
      def match? = false

      private

      attr_reader :context
      def result(kind:, action:, mode:, explanation:, guidance: nil, evidence: {})
        Decision.new(kind:, recommended_action: action, mode:, explanation:, guidance:,
          evidence: context.evidence.merge(evidence))
      end
    end

    class NoProgress < Base
      def match? = context.stop.present? || context.workflow&.failure_reason == GraderLoopProgress::NO_PROGRESS_REASON
      def decision
        stop = context.stop
        result(kind: "grader_loop_no_progress", action: "repair_with_guidance", mode: "failed_step",
          explanation: stop["explanation"].presence || "The grader loop stopped because measured failures did not improve.",
          guidance: "Diagnose the repeated measured failures and give the repair agent specific corrective guidance.",
          evidence: { compared_iterations: stop.slice("previous_iteration", "current_iteration", "repeated_iteration"),
            measured_failure_identities: stop["failing_set"], rounds: stop["rounds"] })
      end
    end

    class WorkspaceUnavailable < Base
      def match? = context.workflow.present? && !context.retry_available?
      def decision
        result(kind: "workspace_unavailable", action: "fresh_implementation", mode: "implementation",
          explanation: "The failed workflow workspace is unavailable, so work cannot safely resume in place.")
      end
    end

    class InfrastructureOnly < Base
      def match?
        context.classification.in?(GraderLoopProgress::UNMEASURED_CLASSIFICATIONS) ||
          Array(context.workflow&.artifact(GraderLoopProgress::ARTIFACT_KEY)).last.to_h["transient_only"] == true
      end
      def decision
        result(kind: "infrastructure_only", action: "rerun_unchanged", mode: "failed_step",
          explanation: "Execution ended without a trustworthy implementation or test verdict.")
      end
    end

    class InterruptedResumable < Base
      INTERRUPTED_CLASSIFICATIONS = %w[agent_interrupted agent_resume_unavailable].freeze
      def match? = INTERRUPTED_CLASSIFICATIONS.include?(context.classification)
      def decision
        result(kind: "interrupted_resumable", action: "resume", mode: "failed_step",
          explanation: "The work was interrupted and retains resumable execution state.")
      end
    end

    class MeasuredFailure < Base
      def match? = context.failed_step.present? && context.retry_available?
      def decision
        result(kind: "measured_failure", action: "repair_with_guidance", mode: "failed_step",
          explanation: "Execution produced a measured implementation or test failure.",
          guidance: "Repair the measured failure; an unchanged rerun is not expected to change the verdict.")
      end
    end

    class RestartFromBase < Base
      def match? = true
      def decision
        result(kind: "restart_from_base", action: "restart", mode: "restart",
          explanation: "No trustworthy resumable recovery target remains; restart from the effective base.")
      end
    end
  end
end
