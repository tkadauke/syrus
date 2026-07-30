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

    if unresolved.empty?
      # All deps are satisfied for execution. Some may be satisfied via "approved in same
      # epic" rather than via merge — their changes are on the dep's branch, not in main
      # yet. Stack on that branch instead of defaulting to main.
      open_unmerged = dependencies.select { |dep|
        dep.depends_on_job.present? &&
          !dep.depends_on_job.dependency_succeeded? &&
          parent_ready?(dep.depends_on_job)
      }
      return force_main! if open_unmerged.empty?
      return false unless open_unmerged.size == 1

      update_parent!(open_unmerged.first.depends_on_job)
      return true
    end

    return false if unresolved.any?(&:pending?)
    return false if unresolved.any? { |dependency| dependency.depends_on_job_id.blank? }
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
      Rails.logger.info("[JobStackResolver] failed to refresh stack footer for #{job.slug}: #{e.class}: #{e.message}")
    end
  end

  def parent_ready?(parent)
    parent.open? &&
      parent.pr_number.present? &&
      parent.branch_name.present? &&
      parent.head_sha.present?
  end
end
