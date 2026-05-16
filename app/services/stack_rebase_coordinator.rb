class StackRebaseCoordinator
  def self.parent_amended(parent)
    new(parent).parent_amended
  end

  def self.parent_merged(parent)
    new(parent).parent_merged
  end

  def self.parent_closed(parent)
    new(parent).parent_closed
  end

  def initialize(parent)
    @parent = parent
  end

  def parent_amended
    refresh_stack_footers(@parent, *@parent.stack_children)
    @parent.stack_children.find_each do |child|
      enqueue_rebase(child)
    end
  end

  def parent_merged
    @parent.stack_children.find_each do |child|
      child.update!(parent_job: nil)
      refresh_stack_footers(@parent, child)
      if child.branch_name.present? && child.pr_number.present?
        enqueue_rebase(child)
      else
        child.start_pending_workflows_if_dependencies_satisfied!
      end
    end
  end

  def parent_closed
    refresh_stack_footers(@parent, *@parent.stack_children)
  end

  private

  def enqueue_rebase(child)
    return if child.closed?
    return if child.branch_name.blank? || child.pr_number.blank?
    return if child.workflows.active.exists?

    workflow = Workflows::Rebase.instantiate(job: child)
    StepDispatcher.start_workflow(workflow)
  end

  def refresh_stack_footers(*jobs)
    jobs.compact.uniq.each do |job|
      PrStackFooter.refresh!(job)
    rescue StandardError => e
      Rails.logger.info("[StackRebaseCoordinator] failed to refresh stack footer for job #{job.id}: #{e.class}: #{e.message}")
    end
  end
end
