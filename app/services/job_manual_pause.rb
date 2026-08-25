class JobManualPause
  def self.pause!(job, by_user:)
    job.pause_manually!(by_user: by_user)
    active_work_units(job).each(&:request_pause!)
  end

  def self.unpause!(job)
    job.unpause_manually!
    units = active_work_units(job).to_a
    resume_active_work_units(units)
    resume_active_work_unit_workflows(units)
    LandingQueueProcessorJob.perform_later if job.approved? || job.landing?
  end

  def self.resume_active_work_units(units)
    units.each do |unit|
      was_manual_pause_blocked = unit.blocked? && unit.blocked_reason == WorkUnits::Gates::ManualPause::REASON
      unit.clear_pause!
      unit.unblock! if was_manual_pause_blocked
    end
  end

  def self.resume_active_work_unit_workflows(units)
    units.filter_map(&:workflow).uniq(&:id).each do |workflow|
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
