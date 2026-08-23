class JobManualPause
  def self.pause!(job, by_user:)
    job.pause_manually!(by_user: by_user)
    active_work_units(job).each(&:request_pause!) if WorkUnits::PathOwnership.work_unit_owned?("manual_pause")
  end

  def self.unpause!(job)
    job.unpause_manually!
    resume_active_work_units(job) if WorkUnits::PathOwnership.work_unit_owned?("manual_pause")
    resume_active_workflows(job)
    LandingQueueProcessorJob.perform_later if job.approved? || job.landing?
  end

  def self.resume_active_work_units(job)
    active_work_units(job).each do |unit|
      unit.clear_pause!
      next unless unit.blocked? && unit.blocked_reason == WorkUnits::Gates::ManualPause::REASON

      result = WorkUnits::Scheduler.evaluate!(unit)
      next unless result.pass?
      next unless unit.workflow

      WorkUnits::Launcher.start!(unit.workflow)
    end
  end

  def self.resume_active_workflows(job)
    job.workflows.where(state: %w[ queued running ]).find_each do |workflow|
      StepDispatcher.clear_start_blocked!(workflow, StepDispatcher::MANUAL_PAUSE_REASON)
      WorkUnits::DeferredPhaseResume.call(workflow.id)
    end
  end

  def self.active_work_units(job)
    WorkUnit
      .joins(:work_unit_members)
      .where(work_unit_members: { job_id: job.id }, state: WorkUnits::Ownership::ACTIVE_STATES)
      .distinct
  end
  private_class_method :active_work_units
end
