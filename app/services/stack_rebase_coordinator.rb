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
    children = stack_children_for_rebase
    refresh_stack_footers(@parent, *children)
    children.each do |child|
      enqueue_rebase(child)
    end
  end

  def parent_merged
    @parent.stack_children.find_each do |child|
      child.update!(parent_job: nil)
      retarget_child_pull_request(child)
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

  def stack_children_for_rebase
    @parent.stack_children.order(id: :desc).to_a
  end

  def enqueue_rebase(child)
    return if child.closed?
    return if child.branch_name.blank? || child.pr_number.blank?
    return if child.workflows.active.exists?

    workflow = Workflows::Rebase.instantiate(job: child, base_branch: child.effective_base_branch)
    StepDispatcher.start_workflow(workflow)
  end

  def retarget_child_pull_request(child)
    return if child.pr_number.blank?

    base = child.effective_base_branch
    GithubClient.for(repository: child.repository, user: child.user)
                .update_pull_request_base(child.repository.slug, child.pr_number, base: base)
  rescue StandardError => e
    Rails.logger.info(
      "[StackRebaseCoordinator] failed to retarget PR for job #{child.id} " \
      "to #{base || child.repository.default_branch}: #{e.class}: #{e.message}"
    )
  end

  def refresh_stack_footers(*jobs)
    jobs.compact.uniq.each do |job|
      PrStackFooter.refresh!(job)
    rescue StandardError => e
      Rails.logger.info("[StackRebaseCoordinator] failed to refresh stack footer for job #{job.id}: #{e.class}: #{e.message}")
    end
  end
end
