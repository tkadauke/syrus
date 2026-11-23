class MainBranchHealthProvider
  include Syrus::Plugin::WorkGate
  include Syrus::Plugin::SystemAlertProvider
  include Syrus::Plugin::RepairClassifier
  REASON = "main_branch_broken"
  MESSAGE = "Repository landing is paused because the main branch is unhealthy."

  def self.work_gate(context)
    workflow = context.workflow
    job = context.job
    return [] unless job
    return [] if workflow && StepDispatcher::MAIN_HEALTH_EXEMPT_TRIGGERS.include?(workflow.trigger_kind)
    return [] if MainHealthChangedService.fix_main_job?(job)

    repository = job.repository
    return [] unless repository.main_branch_health_enabled?
    return [] unless repository.strict_breakage_policy?
    return [] unless repository.main_branch_repair_blocks_work?
    return [] unless repository.landing_paused? && repository.main_health_broken?

    [ Syrus::Plugin::WorkPolicy::Veto.new(
      reason: REASON,
      message: MESSAGE,
      landing: true,
      details: {
        "repository_id" => repository.id,
        "repository_slug" => repository.slug,
        "main_health_state" => "broken"
      }
    ) ]
  end

  def self.system_alerts
    [ *SystemAlerts.send(:no_progress_main_branch_repairs), *SystemAlerts.send(:stuck_main_branch_repairs) ]
  end

  def self.classify_repair(context)
    return unless context.workflow

    result = MainBranchFailureClassifier.call(workflow: context.workflow, failed_grader_steps: context.failed_steps)
    result if result.classifications.any?
  end
end
