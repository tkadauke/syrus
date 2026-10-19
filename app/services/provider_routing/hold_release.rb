module ProviderRouting
  class HoldRelease
    def self.call(hold:, user:, reason:, override: false)
      ProviderRoutingHold.transaction do
        workflow = hold.workflow
        workflow.lock!
        hold.lock!
        if hold.active?
          hold.update!(
            status: override ? "overridden" : "released",
            released_at: Time.current,
            released_by_user: user,
            release_reason: reason,
            release_kind: override ? "override" : "manual"
          )
        end
        artifacts = workflow.artifacts.to_h
        released_ids = (Array(artifacts["released_provider_routing_hold_rule_ids"]) | [ hold.provider_routing_rule_id ]).compact
        workflow.update!(artifacts: artifacts.merge("released_provider_routing_hold_rule_ids" => released_ids))
      end
      WorkflowPhaseAdmissionJob.enqueue_once(hold.workflow_id, hold.step_id, force: true)
      hold
    end
  end
end
