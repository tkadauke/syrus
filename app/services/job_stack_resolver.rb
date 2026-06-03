class JobStackResolver
  def initialize(job)
    @job = job
  end

  def ready?
    resolve!
  end

  def resolve!
    return force_main! if @job.stack_base_forces_main?

    dependencies = @job.dependencies.includes(:depends_on_job).to_a
    return force_main! if dependencies.empty?

    unresolved = dependencies.reject(&:dependency_succeeded?)
    return force_main! if unresolved.empty?
    return false if unresolved.any?(&:pending?)
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

    old_parent = @job.parent_job
    @job.update!(parent_job: parent)
    refresh_stack_footers(old_parent, parent, @job)
  end

  def refresh_stack_footers(*jobs)
    jobs.compact.uniq.each do |job|
      PrStackFooter.refresh!(job)
    rescue StandardError => e
      Rails.logger.info("[JobStackResolver] failed to refresh stack footer for job #{job.id}: #{e.class}: #{e.message}")
    end
  end

  def parent_ready?(parent)
    parent.open? &&
      parent.pr_number.present? &&
      parent.branch_name.present? &&
      parent.head_sha.present?
  end
end
