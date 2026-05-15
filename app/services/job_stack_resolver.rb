class JobStackResolver
  def initialize(job)
    @job = job
  end

  def ready?
    resolve!
  end

  def resolve!
    return force_main! if @job.stack_base_main?

    dependencies = @job.dependencies.includes(:depends_on_job).to_a
    return force_main! if dependencies.empty?
    return false if dependencies.any?(&:pending?)

    unresolved = dependencies.reject { |dependency| dependency.depends_on_job.dependency_succeeded? }
    return force_main! if unresolved.empty?
    return false unless unresolved.size == 1

    parent = unresolved.first.depends_on_job
    return false unless parent_ready?(parent)

    update_parent!(parent)
    true
  end

  private

  def force_main!
    update_parent!(nil)
    true
  end

  def update_parent!(parent)
    parent_id = parent&.id
    return if @job.parent_job_id == parent_id

    @job.update!(parent_job: parent)
  end

  def parent_ready?(parent)
    parent.open? &&
      parent.pr_number.present? &&
      parent.branch_name.present? &&
      parent.head_sha.present?
  end
end
