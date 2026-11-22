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
      resume_unit(unit) if was_manual_pause_blocked
    end
  end

  # A started landing gave its repository landing slot back when it was paused
  # (WorkUnit::EXTERNALLY_CLEARED_BLOCKED_REASONS). If another landing took the
  # slot meanwhile, re-acquiring it conflicts: leave the unit queued without
  # the slot instead of failing the unpause. Its next Run start takes the slot
  # through WorkUnit#mark_running!, and RunJob defers that start while the
  # slot is held, so the landing waits its turn.
  def self.resume_unit(unit)
    unit.resume_for_workflow!
  rescue WorkUnits::Launcher::LockConflict => e
    Rails.logger.info(
      "[JobManualPause] WorkUnit ##{unit.id} unpaused while #{e.lock_key} is held by WorkUnit ##{e.work_unit&.id}; " \
      "it waits for the lock at its next start"
    )
    unit.reload.unblock!
  end
  private_class_method :resume_unit

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
