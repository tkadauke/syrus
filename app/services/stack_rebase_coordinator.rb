class StackRebaseCoordinator
  def self.parent_amended(parent)
    new(parent).parent_amended
  end

  def self.parent_merged(parent)
    new(parent).parent_merged
  end

  def initialize(parent)
    @parent = parent
  end

  def parent_amended
    @parent.stack_children.find_each do |child|
      enqueue_rebase(child)
    end
  end

  def parent_merged
    @parent.stack_children.find_each do |child|
      child.update!(parent_job: nil)
      if child.branch_name.present? && child.pr_number.present?
        enqueue_rebase(child)
      else
        child.start_pending_workflows_if_dependencies_satisfied!
      end
    end
  end

  private

  def enqueue_rebase(child)
    return if child.closed?
    return if child.branch_name.blank? || child.pr_number.blank?
    return if child.workflows.active.exists?

    workflow = Workflows::Rebase.instantiate(job: child)
    StepDispatcher.start_workflow(workflow)
  end
end
