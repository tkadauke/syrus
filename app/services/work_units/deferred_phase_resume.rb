module WorkUnits
  class DeferredPhaseResume
    Result = Data.define(:workflow, :run, :work_unit, :status, :reason) do
      def started? = status == "started"
      def blocked? = status == "blocked"
      def legacy? = status == "legacy"
    end

    def self.call(workflow_id, step_id = nil)
      workflow = Workflow.find_by(id: workflow_id)
      return Result.new(workflow: nil, run: nil, work_unit: nil, status: "missing", reason: nil) unless workflow

      new(workflow, step_id: step_id).call
    end

    def initialize(workflow, step_id: nil)
      @workflow = workflow
      @step_id = step_id
    end

    def call
      return result("terminal") unless workflow.queued? || workflow.running?
      return legacy_resume if legacy_replay_workflow?
      return result("missing_work_unit") unless work_unit&.active?

      step = target_step
      return result("no_step") unless step&.queued?
      return result("run_exists") if step.runs.any?

      prior_block_reason = WorkUnits::StartBlock.for(workflow).reason
      gate_result = WorkUnits::Scheduler.evaluate!(work_unit, step: step)
      if gate_result.blocked?
        WorkUnits::Launcher.schedule_blocked_recheck!(workflow, gate_result)
        return result("blocked", reason: gate_result.reason)
      end
      StepDispatcher.clear_start_blocked!(workflow.reload, prior_block_reason) if prior_block_reason.present?

      if first_step?(step)
        launcher_result = WorkUnits::Launcher.start!(workflow)
        return Result.new(
          workflow: workflow,
          run: launcher_result.run,
          work_unit: work_unit,
          status: launcher_result.status,
          reason: launcher_result.reason
        )
      end

      run = StepDispatcher.resume_deferred_phase(workflow.id, step.id, check_phase_admission: false)
      Result.new(workflow: workflow, run: run, work_unit: work_unit, status: run ? "started" : "not_started", reason: nil)
    end

    private

    attr_reader :workflow, :step_id

    def work_unit
      @work_unit ||= workflow.work_unit
    end

    def legacy_resume
      run = StepDispatcher.resume_deferred_phase(workflow.id, step_id)
      Result.new(workflow: workflow, run: run, work_unit: work_unit, status: "legacy", reason: nil)
    end

    def legacy_replay_workflow?
      !work_unit&.active? && workflow.trigger_kind == WorkUnits::Ownership::LEGACY_REPLAY_TRIGGER_KIND
    end

    def target_step
      @target_step ||= if step_id
        workflow.steps.find_by(id: step_id)
      else
        StepDispatcher.next_queued_step_without_run(workflow)
      end
    end

    def first_step?(step)
      step.id == workflow.first_step&.id
    end

    def result(status, reason: nil)
      Result.new(workflow: workflow, run: nil, work_unit: work_unit, status: status, reason: reason)
    end
  end
end
