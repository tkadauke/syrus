# Locks a record's ancestry top-down, in the hierarchical row-lock order
# (NY40): Epic, Job, WorkIntent, WorkUnit, Workflow, Step, Run. A transaction
# that can change a Workflow's state, or anything under it, calls this first;
# the rollups it writes afterwards (a Step's outcome to its Workflow, a
# Workflow's to its WorkUnit, intent, Job and Epic) then touch rows it already
# holds, which is in order.
#
# Uses locking queries, never lock!, so the caller's unsaved changes on the
# records it passes are kept. Rows already held re-lock for free.
module Lineage
  module_function

  def lock!(record)
    lock_all!([ record ])
    record
  end

  # Several records' ancestries at once, possibly across Jobs: every row of a
  # model is locked before any row of the next model down, ids ascending
  # within a model, so the order holds across lineages too.
  #
  # Each WorkUnit's member Jobs come with it, a merge-train Workflow's train
  # members, and each Job's active Workflows, with their intents and
  # WorkUnits:
  # a Workflow event can cancel its siblings (superseded retries, a pending
  # closure), and a sibling's ancestry taken after this Workflow would be out
  # of order.
  def lock_all!(records)
    ids_by_model = Hash.new { |hash, klass| hash[klass] = [] }
    records.compact.each do |record|
      ancestry(record).each { |klass, id| ids_by_model[klass] << id }
    end
    member_jobs(ids_by_model[WorkUnit].uniq).each do |job_id, epic_id|
      ids_by_model[Job] << job_id
      ids_by_model[Epic] << epic_id if epic_id
    end
    siblings = active_siblings(ids_by_model[Job].uniq)
    siblings.each do |workflow|
      ancestry(workflow).each { |klass, id| ids_by_model[klass] << id }
    end
    train_member_jobs([ *records.grep(Workflow), *siblings ]).each do |job_id, epic_id|
      ids_by_model[Job] << job_id
      ids_by_model[Epic] << epic_id if epic_id
    end
    MODELS.each do |klass|
      ids = ids_by_model[klass].uniq.sort
      klass.lock.where(id: ids).order(:id).to_a if ids.any?
    end
    records
  end

  MODELS = [ Epic, Job, WorkIntent, WorkUnit, Workflow, Step, Run ].freeze
  ACTIVE_WORKFLOW_STATES = %w[queued running].freeze

  # A WorkUnit's member and scope Jobs, with their Epics: marking the unit
  # running or terminal locks them.
  def member_jobs(unit_ids)
    return [] if unit_ids.empty?

    job_ids = WorkUnitMember.where(work_unit_id: unit_ids).pluck(:job_id)
    job_ids += WorkUnit.where(id: unit_ids, scope_type: "job").pluck(:scope_id)
    Job.where(id: job_ids.compact.uniq).pluck(:id, :epic_id)
  end

  # A merge-train Workflow's train members, with their Epics: its failure
  # and landing handlers move every member Job.
  def train_member_jobs(workflows)
    train_ids = workflows.uniq.filter_map do |workflow|
      workflow.artifact("merge_train_id") if workflow.trigger_kind == "merge_train"
    end
    return [] if train_ids.empty?

    Job.where(id: MergeTrainMember.where(merge_train_id: train_ids).select(:job_id)).pluck(:id, :epic_id)
  end

  def active_siblings(job_ids)
    return [] if job_ids.empty?

    Workflow.where(job_id: job_ids, state: ACTIVE_WORKFLOW_STATES).includes(work_unit: :work_intent).order(:id).to_a
  end

  # A Job's active work, top down: the Job and its active Workflows' whole
  # subtrees, every Step before any Run. Cancelling a Run cascades to its
  # Workflow's other Steps, so locking only the Runs' own ancestries leaves
  # those Steps after a Run.
  def lock_active_work!(job, workflows: nil)
    workflows ||= Workflow.where(job_id: job.id, state: ACTIVE_WORKFLOW_STATES).order(:id).to_a
    lock_all!([ job, *workflows ])
    lock_subtree!(*workflows) if workflows.any?
    job
  end

  # The ancestries and every Workflow, Step and Run below +records+, top
  # down, across all of them at once. A dependent: :destroy cascade deletes
  # children before parents, and a cascade across Jobs cancels one subtree
  # after another; with every subtree locked first, each write touches a row
  # the transaction holds.
  def lock_subtree!(*records)
    records = records.flatten.compact
    job_ids = records.grep(Job).map(&:id)
    workflows = job_ids.any? ? Workflow.where(job_id: job_ids).order(:id).to_a : []
    lock_all!([ *records, *workflows ])
    workflow_ids = workflows.map(&:id) + records.grep(Workflow).map(&:id)
    step_ids = Step.where(workflow_id: workflow_ids).pluck(:id) + records.grep(Step).map(&:id)
    Step.lock.where(id: step_ids.uniq).order(:id).to_a if step_ids.any?
    run_ids = Run.where(step_id: step_ids).pluck(:id)
    run_ids |= Run.where(job_id: job_ids).pluck(:id) if job_ids.any?
    Run.lock.where(id: run_ids).order(:id).to_a if run_ids.any?
    records.one? ? records.first : records
  end

  # [[model class, id], ...] from the top of the hierarchy down.
  def ancestry(record)
    run = record if record.is_a?(Run)
    step = record.is_a?(Step) ? record : run&.step
    workflow = record.is_a?(Workflow) ? record : step&.workflow
    unit = record.is_a?(WorkUnit) ? record : workflow&.work_unit
    workflow ||= unit&.workflow
    job = record.is_a?(Job) ? record : (workflow&.job || run&.job)
    intent = unit&.work_intent

    [
      [ Epic, job&.epic_id ],
      [ Job, job&.id ],
      [ WorkIntent, intent&.id ],
      [ WorkUnit, unit&.id ],
      [ Workflow, workflow&.id ],
      [ Step, step&.id ],
      [ Run, run&.id ]
    ].select { |_klass, id| id.present? }
  end
end
