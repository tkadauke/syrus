module ProviderRouting
  class HoldReevaluator
    def self.call(workflow:, step: nil)
      new(workflow:, step:).call
    end

    def initialize(workflow:, step:)
      @workflow = workflow
      @step = step
    end

    def call
      hold = workflow.provider_routing_holds.active.first
      return true unless hold
      return false if hold.resumption_mode == "manual"
      return false if hold.resumption_mode == "until_time" && hold.next_reevaluation_at.future?

      held_step = hold.step
      selection = ProviderRouting::AvailabilitySelector.call(
        job: workflow.job.reload,
        task_key: held_step&.kind || workflow.trigger_kind,
        trigger: held_step && StepDispatcher.provider_invocation_for(held_step),
        workflow_trigger_kind: workflow.trigger_kind,
        original_candidate: current_candidate,
        released_hold_rule_ids: released_rule_ids(hold)
      )
      artifacts = workflow.artifacts.to_h.merge("agent_provider_routing_decision" => selection.artifact)
      unless selection.held?
        artifacts["released_provider_routing_hold_rule_ids"] = released_rule_ids(hold)
      end
      workflow.update!(artifacts: artifacts)
      ProviderRouting::HoldAdmission.apply!(workflow: workflow, decision: selection, step: held_step)
      !selection.held?
    end

    private

    attr_reader :workflow, :step

    def current_candidate
      ProviderRouting::AvailabilitySelector.candidate(
        provider: workflow.agent_provider,
        model: workflow.model,
        effort_level: workflow.effort_level
      )
    end

    def released_rule_ids(hold)
      ids = Array(workflow.artifact("released_provider_routing_hold_rule_ids"))
      hold.resumption_mode == "until_time" ? ids | [ hold.provider_routing_rule_id ] : ids
    end
  end
end
