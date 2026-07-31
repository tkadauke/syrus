require "set"

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

      parent = stack_parent_for(open_unmerged)
      return false unless parent

      update_parent!(parent)
      return true
    end

    return false if unresolved.any?(&:pending?)
    return false if unresolved.any? { |dependency| dependency.depends_on_job_id.blank? }

    parent = stack_parent_for(unresolved)
    return false unless parent
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

  def stack_parent_for(dependencies)
    parents = dependencies.map(&:depends_on_job).compact.uniq
    return parents.first if parents.size == 1

    downstream = parents.reject do |candidate|
      (parents - [ candidate ]).any? do |other_parent|
        reaches_job?(other_parent, candidate)
      end
    end
    return nil unless downstream.size == 1

    parent = downstream.first
    redundant = parents - [ parent ]
    Rails.logger.info(
      "[JobStackResolver] #{job_slug(@job)} using #{job_slug(parent)} as stack parent; " \
      "ignoring redundant transitive dependencies #{redundant.map { |dependency| job_slug(dependency) }.join(", ")}"
    )
    parent
  end

  def reaches_job?(from, target, seen = Set.new)
    return true if from.id == target.id
    return false if seen.include?(from.id)

    seen << from.id
    from.dependencies.includes(:depends_on_job).any? do |dependency|
      next false if dependency.depends_on_job.blank?

      reaches_job?(dependency.depends_on_job, target, seen)
    end
  end

  def job_slug(job)
    job.respond_to?(:slug) ? job.slug : "JOB-#{job.id}"
  end
end
