module Workflows
  # Attaches Steps to an array of Workflows without letting MySQL sort them.
  #
  # `has_many :steps, -> { order(:position, :id) }` means any preload of the
  # association emits `ORDER BY position, id`. Across an `IN` list of workflow
  # ids the (workflow_id, position) index cannot serve that order, so MySQL
  # filesorts the selected rows -- and `steps.details` is a JSON column that
  # grader Steps fill with command output. A wide enough sort row exhausts the
  # sort buffer and raises `Out of sort memory`, which took the reconciler
  # down in production for several hours.
  #
  # Loading the rows unsorted and ordering them in Ruby costs nothing at these
  # sizes and cannot raise. Preloading a single Workflow's Steps is fine
  # without this -- `workflow_id = ?` plus that index needs no sort -- so this
  # is for the multi-id case.
  module StepPreloader
    def self.attach!(workflows)
      workflows = Array(workflows)
      return workflows if workflows.empty?

      steps_by_workflow_id = Step.where(workflow_id: workflows.map(&:id)).reorder(nil).to_a.group_by(&:workflow_id)
      workflows.each do |workflow|
        ordered = steps_by_workflow_id.fetch(workflow.id, []).sort_by { |step| [ step.position, step.id ] }
        # Point each Step back at this exact Workflow instance, the way a
        # preload's inverse would. Without it `step.workflow` re-queries and
        # hands back a second instance holding database state, while the
        # caller still holds the state it is reasoning about -- and the two
        # disagree the moment something has moved the Workflow on.
        ordered.each { |step| step.association(:workflow).target = workflow }
        association = workflow.association(:steps)
        association.target = ordered
        association.loaded!
      end
      workflows
    end
  end
end
