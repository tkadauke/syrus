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
      queued_workflows.each do |workflow|
        workflow.association(:job).target = job if workflow.job_id == job.id
        next unless intent_ready_for?(workflow)

        result = start_workflow(workflow)
        started = true if result&.started? || result&.blocked?
      end
      start_requested_intents_without_active_units! { started = true }
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
      workflow_intent_scope = if queued_workflow_ids.empty?
        WorkIntent.none
      else
        WorkIntent
          .joins(:work_units)
          .where(work_units: { workflow_id: queued_workflow_ids })
      end

      WorkIntent
        .where(id: workflow_intent_scope.select(:id))
        .or(job_scoped_current_intents)
        .where(state: %w[requested waiting])
        .distinct
    end

    def job_scoped_current_intents
      WorkIntent.where(scope_type: "job", scope_id: job.id, state: %w[requested waiting])
    end

    def start_requested_intents_without_active_units!
      job_scoped_current_intents.find_each do |intent|
        next if WorkUnits::Ownership.active_for_job?(job)
        next if intent.work_units.where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES).exists?

        result = start_intent(intent)
        next unless result

        yield if result.started? || result.blocked?
      end
    end

    def start_workflow(workflow)
      WorkUnits::Launcher.start!(workflow)
    rescue WorkUnits::Launcher::LockConflict => e
      Rails.logger.info(
        "[WorkIntents::JobWakeup] #{job.slug}: skipped starting #{workflow.slug}; " \
        "#{e.lock_key} is already owned by #{e.work_unit&.slug}"
      )
      nil
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      handle_active_dedup_collision!(e, workflow.trigger_kind, workflow.slug)
    end

    def start_intent(intent)
      WorkIntents::Scheduler.start_ready!(intent)
    rescue WorkUnits::Launcher::LockConflict => e
      Rails.logger.info(
        "[WorkIntents::JobWakeup] #{job.slug}: skipped starting WorkIntent ##{intent.id}; " \
        "#{e.lock_key} is already owned by #{e.work_unit&.slug}"
      )
      nil
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      handle_active_dedup_collision!(e, intent.kind, "WorkIntent ##{intent.id}")
    end

    def handle_active_dedup_collision!(error, kind, label)
      raise unless WorkUnits::Launcher.active_dedup_unique_violation?(error)

      dedup_key = "job:#{job.id}:#{kind}"
      owner = WorkUnits::Ownership.active_unit_for_dedup_key(dedup_key)
      raise unless owner

      Rails.logger.info(
        "[WorkIntents::JobWakeup] #{job.slug}: skipped starting #{label}; " \
        "#{dedup_key} is already owned by #{owner.slug}"
      )
      nil
    end

    def queued_workflows
      @queued_workflows ||= begin
        WorkUnitMember
          .joins(work_unit: :workflow)
          .where(job_id: job.id, work_units: { state: %w[queued blocked] }, workflows: { state: "queued" })
          .includes(work_unit: :workflow)
          .map { |member| member.work_unit.workflow }
          .uniq(&:id)
      end
    end

    def queued_workflow_ids
      queued_workflows.map(&:id)
    end
  end
end
