module WorkIntents
  class JobWakeup
    def self.call(job)
      new(job).call
    end

    def initialize(job)
      @job = job
    end

    def call
      release_epic_block_if_ready!

      unless execution_dependencies_ready?
        mark_current_intents_waiting!
        return false
      end

      return false unless runnable_state?
      return false unless job.stack_ready_for_execution?
      return false unless job.ready_for_execution?

      started = false
      queued_workflows.find_each do |workflow|
        workflow.association(:job).target = job
        next unless intent_ready_for?(workflow)

        WorkUnits::Launcher.start!(workflow)
        started = true
      end
      started
    end

    private

    attr_reader :job

    def release_epic_block_if_ready!
      return unless job.may_release_epic_block?
      return unless execution_dependencies_ready?

      job.release_epic_block!
    end

    def runnable_state?
      job.queued? || job.running? || job.implemented?
    end

    def execution_dependencies_ready?
      job.dependencies_satisfied_for_execution?
    end

    def mark_current_intents_waiting!
      current_intents.each { |intent| WorkIntents::Scheduler.evaluate!(intent) }
    end

    def intent_ready_for?(workflow)
      intent = workflow.work_unit&.work_intent
      return true unless intent

      WorkIntents::Scheduler.evaluate!(intent).pass?
    end

    def current_intents
      WorkIntent
        .joins(:work_units)
        .where(work_units: { workflow_id: queued_workflows.select(:id) })
        .where(state: %w[requested waiting])
        .distinct
    end

    def queued_workflows
      job.workflows.where(state: "queued")
    end
  end
end
