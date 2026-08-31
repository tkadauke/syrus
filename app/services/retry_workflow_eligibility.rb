class RetryWorkflowEligibility
  Result = Data.define(:eligible, :code, :message) do
    def eligible? = eligible
  end

  def self.call(...) = new(...).call

  def initialize(job:, workflow: nil)
    @job = job
    @workflow = workflow
  end

  def call
    return failure("closed", closed_job_message) if job.closed?
    return failure("approved", "Job is already approved for landing - unapprove it before retrying.") if job.approved? || job.landing?
    if job.landing_failure_reason.present?
      return failure("landing_failed", "Landing failed - reapprove the Job or retry the failed landing workflow instead of retrying implementation.")
    end
    return failure("pr_ready", "PR is already current and checks are passing.") if pr_ready?
    return failure("active_run", "A Run is already in progress - wait for it to finish.") if other_active_run?
    return failure("duplicate_retry", "A retry workflow is already queued or running for this Job.") if duplicate_active_retry_workflow?
    return failure("superseded", "Retry workflow was superseded by a newer successful workflow.") if workflow_superseded?
    return failure("initial_not_run", "The initial workflow has not run yet - start or wait for it before retrying.") unless initial_workflow_ran?

    Result.new(eligible: true, code: nil, message: nil)
  end

  private

  attr_reader :job, :workflow

  def failure(code, message)
    Result.new(eligible: false, code: code, message: message)
  end

  def closed_job_message
    if job.infrastructure?
      "Thread is closed - use Start over to begin a new one."
    else
      "Thread is closed - reopen it to continue."
    end
  end

  def other_active_run?
    scope = job.runs.active
    scope = scope.where.not(step_id: workflow.steps.select(:id)) if workflow
    scope.exists?
  end

  def duplicate_active_retry_workflow?
    active_workflows = job.active_runtime_workflows
    unit_kinds_by_workflow_id = work_unit_kinds_by_workflow_id(active_workflows)

    active_workflows.any? do |active_workflow|
      retry_workflow_attempt?(
        active_workflow,
        work_unit_kind: unit_kinds_by_workflow_id[active_workflow.id]
      ) && active_workflow.id != workflow&.id
    end
  end

  def workflow_superseded?
    retry_workflow_attempt?(workflow, work_unit_kind: work_unit_kind_for(workflow)) &&
      workflow.superseded_by_newer_successful_publication?
  end

  def retry_workflow_attempt?(candidate, work_unit_kind: nil)
    return false unless candidate

    WorkDefinitions.for(work_unit_kind || candidate.trigger_kind).retry_workflow_attempt?
  rescue WorkDefinitions::UnknownKind
    false
  end

  def work_unit_kinds_by_workflow_id(workflows)
    workflow_ids = workflows.map(&:id).compact
    return {} if workflow_ids.empty?

    WorkUnit.where(workflow_id: workflow_ids).pluck(:workflow_id, :kind).to_h
  end

  def work_unit_kind_for(candidate)
    return nil unless candidate

    WorkUnit.where(workflow_id: candidate.id).pick(:kind)
  end

  def pr_ready?
    job.pr_number.present? &&
      job.branch_name.present? &&
      job.commits_behind_base.to_i.zero? &&
      job.pr_checks_state == "passing"
  end

  def initial_workflow_ran?
    initial = job.workflows.where(trigger_kind: "initial").order(:created_at, :id).first
    return false unless initial
    return true if initial.started_at.present? || initial.finished_at.present?
    return true if initial.running? || initial.terminal?

    initial.runs.where.not(started_at: nil).exists? || initial.runs.terminal.exists?
  end
end
