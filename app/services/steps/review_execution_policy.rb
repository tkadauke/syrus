module Steps
  module ReviewExecutionPolicy
    extend ActiveSupport::Concern

    private

    def skip_or_fail_unavailable_review!(review_kind:, reason:, message:, config_required:)
      if config_required
        fail_with!(
          :review_execution_unavailable,
          "#{review_kind} review could not execute: #{message}",
          evidence: { review_kind: review_kind, reason: reason }
        )
      end

      WorkflowWarnings.record!(
        workflow: workflow,
        step: step,
        kind: "review_execution_skipped",
        severity: "medium",
        title: "#{review_kind.humanize} skipped: #{message}",
        evidence: {
          "review_kind" => review_kind,
          "reason" => reason,
          "run_id" => run.id,
          "step_id" => step.id
        }
      )

      raise Base::StepSkipped.new(message, reason: reason)
    end
  end
end
