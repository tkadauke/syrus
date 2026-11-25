module Steps
  module ReviewExecutionPolicy
    extend ActiveSupport::Concern

    PANEL_MEMBER_UNAVAILABLE_CODES = %w[
      provider_policy_refusal provider_model_unsupported provider_auth_expired
      provider_auth_or_config provider_prompt_too_long
    ].freeze

    private

    def handle_unavailable_panel_member!(exception, review_kind:)
      details = step.details.to_h
      return false unless details["panel_member"]

      problem = exception.respond_to?(:problem) ? exception.problem : nil
      return false unless problem && PANEL_MEMBER_UNAVAILABLE_CODES.include?(problem.code)

      reason = "#{problem.code}: #{exception.message}"
      case details.fetch("on_unavailable", "fail")
      when "drop"
        skip_review!(reason)
        raise Base::StepSkipped.new(reason, reason: problem.code)
      when "hold"
        raise Base::CannotProceed, "#{review_kind} panel member #{details['provider']} is unavailable: #{reason}"
      else
        fail_with!(
          :review_execution_unavailable,
          "#{review_kind} panel member #{details['provider']} is unavailable and policy is fail: #{reason}",
          evidence: { review_kind:, provider: details["provider"], reason: problem.code }
        )
      end
    end

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
