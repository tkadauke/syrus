module ProviderRouting
  class HoldAdmission
    DEFAULT_REEVALUATION = 5.minutes

    def self.apply!(workflow:, decision:, step: nil, now: Time.current)
      new(workflow:, decision:, step:, now:).apply!
    end

    def initialize(workflow:, decision:, step:, now:)
      @workflow = workflow
      @decision = decision
      @step = step
      @now = now
    end

    def apply!
      return clear! unless decision&.held?

      rule = decision.routing_resolution.matched_rule
      policy = rule.serialized_action["resumption"].to_h
      mode = (policy["mode"].presence || "manual").to_s
      next_at = next_reevaluation_at(mode, policy)
      hold = nil
      ProviderRoutingHold.transaction do
        workflow.lock!
        hold = workflow.provider_routing_holds.active.first_or_initialize
        hold.assign_attributes(
          step: step,
          provider_routing_rule: rule,
          resumption_mode: mode,
          reason: rule.serialized_action["reason"].presence || "Held by provider routing rule",
          condition_evidence: decision.routing_resolution.match_details,
          matched_scope: decision.routing_resolution.explanation.slice("source_scope", "source_id", "matched_rule"),
          next_reevaluation_at: next_at
        )
        hold.save!
      end
      WorkflowPhaseAdmissionJob.enqueue_once(workflow.id, step&.id, wait_until: next_at, priority: workflow.solid_queue_priority) if next_at
      hold
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    attr_reader :workflow, :decision, :step, :now

    def clear!
      workflow.provider_routing_holds.active.find_each do |hold|
        hold.update!(status: "cleared", released_at: now, release_kind: automatic_release_kind(hold))
      end
      nil
    end

    def automatic_release_kind(hold)
      hold.resumption_mode == "until_time" ? "time_elapsed" : "conditions_cleared"
    end

    def next_reevaluation_at(mode, policy)
      return Time.zone.parse(policy.fetch("at")) if mode == "until_time"
      now + duration(policy["interval_seconds"]) if mode == "when_conditions_clear"
    end

    def duration(value)
      seconds = Integer(value || DEFAULT_REEVALUATION.to_i)
      [ seconds, 30 ].max.seconds
    rescue ArgumentError, TypeError
      DEFAULT_REEVALUATION
    end
  end
end
