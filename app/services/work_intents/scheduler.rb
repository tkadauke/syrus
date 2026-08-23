module WorkIntents
  class Scheduler
    StartResult = Data.define(
      :intent,
      :gate_result,
      :workflow,
      :work_unit,
      :launch_result,
      :status,
      :reason
    ) do
      def started? = status == "started"
      def blocked? = status == "blocked"
      def waiting? = status == "waiting"
      def already_active? = status == "already_active"
    end

    def self.evaluate!(intent, gates: nil)
      new(intent, gates: gates).evaluate!
    end

    def self.start_ready!(intent, artifacts: nil, agent_provider: nil, **options)
      new(intent, gates: nil).start_ready!(artifacts: artifacts, agent_provider: agent_provider, **options)
    end

    def initialize(intent, gates:)
      @intent = intent
      @gates = gates || intent.definition.intent_gates
    end

    def evaluate!
      gates.each do |gate|
        result = gate.call(intent)
        next if result.pass?

        intent.wait!(
          reason: result.reason,
          wait_until: result.retry_at,
          details: result.details
        )
        return result
      end

      intent.request! if intent.waiting? && managed_wait_reason?(intent.wait_reason)
      GateResult.pass
    end

    def start_ready!(artifacts: nil, agent_provider: nil, **options)
      active_unit_ids = intent.work_units.where(state: TerminalUnitSync::ACTIVE_UNIT_STATES).pluck(:id)
      if active_unit_ids.any?
        return StartResult.new(
          intent: intent,
          gate_result: nil,
          workflow: nil,
          work_unit: nil,
          launch_result: nil,
          status: "already_active",
          reason: "active_work_units:#{active_unit_ids.inspect}"
        )
      end

      gate_result = evaluate!
      unless gate_result.pass?
        return StartResult.new(
          intent: intent,
          gate_result: gate_result,
          workflow: nil,
          work_unit: nil,
          launch_result: nil,
          status: "waiting",
          reason: gate_result.reason
        )
      end

      workflow = WorkUnits::Launcher.instantiate_intent!(
        intent,
        artifacts: artifacts,
        agent_provider: agent_provider,
        **options
      )
      launch_result = WorkUnits::Launcher.start!(workflow)
      status = launch_result.blocked? ? "blocked" : "started"
      StartResult.new(
        intent: intent,
        gate_result: gate_result,
        workflow: workflow,
        work_unit: launch_result.work_unit || workflow.work_unit,
        launch_result: launch_result,
        status: status,
        reason: launch_result.reason
      )
    end

    private

    attr_reader :intent, :gates

    def managed_wait_reason?(reason)
      managed_wait_reasons.include?(reason)
    end

    def managed_wait_reasons
      @managed_wait_reasons ||= gates.filter_map do |gate|
        gate.const_get(:REASON) if gate.const_defined?(:REASON, false)
      end
    end
  end
end
