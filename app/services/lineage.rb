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
  def lock_all!(records)
    ids_by_model = Hash.new { |hash, klass| hash[klass] = [] }
    records.compact.each do |record|
      ancestry(record).each { |klass, id| ids_by_model[klass] << id }
    end
    MODELS.each do |klass|
      ids = ids_by_model[klass].uniq.sort
      klass.lock.where(id: ids).order(:id).to_a if ids.any?
    end
    records
  end

  MODELS = [ Epic, Job, WorkIntent, WorkUnit, Workflow, Step, Run ].freeze

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
