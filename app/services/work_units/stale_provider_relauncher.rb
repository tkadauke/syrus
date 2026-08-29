module WorkUnits
  class StaleProviderRelauncher
    PREEMPTION_REASON = "provider_changed".freeze

    def self.stale?(work_unit) = new(work_unit).stale?
    def self.release!(work_unit) = new(work_unit).release!

    def self.release_for_intent!(intent)
      intent.work_units
        .where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
        .includes(workflow: :job)
        .find_each
        .select { |unit| stale?(unit) }
        .each { |unit| release!(unit) }
    end

    def self.release_for_job!(job)
      WorkUnit
        .joins(:work_unit_members)
        .where(work_unit_members: { job_id: job.id })
        .where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
        .includes(workflow: :job)
        .find_each
        .select { |unit| stale?(unit) }
        .each { |unit| release!(unit) }
    end

    def initialize(work_unit)
      @work_unit = work_unit
    end

    def stale?
      return false unless work_unit&.blocked?
      return false unless work_unit.blocked_reason == WorkUnits::Gates::ProviderAvailability::REASON
      return false unless workflow&.job
      return false unless desired_provider.present?
      return false if workflow.agent_provider == desired_provider

      safe_to_replace?
    end

    def release!
      return false unless stale?

      WorkUnits::WorkflowCancellation.cancel!(
        workflow,
        reason: PREEMPTION_REASON,
        artifacts: {
          "cancelled_reason" => Workflow::SUPERSEDED_BY_NEWER_WORKFLOW_REASON,
          "provider_relaunch" => {
            "previous_provider" => workflow.agent_provider,
            "desired_provider" => desired_provider,
            "work_unit_id" => work_unit.id,
            "work_intent_id" => work_unit.work_intent_id
          }
        },
        by_work_unit: nil
      )
      true
    end

    def desired_provider
      @desired_provider ||= Job.find_by(id: workflow.job_id)&.workflow_agent_provider.presence
    end

    private

    attr_reader :work_unit

    def workflow
      @workflow ||= work_unit.workflow
    end

    def safe_to_replace?
      return true if workflow.queued?

      workflow.running? && no_active_descendants?
    end

    def no_active_descendants?
      !workflow.steps.where(state: %w[running failed]).exists? &&
        !workflow.runs.where(state: %w[running failed]).exists?
    end
  end
end
