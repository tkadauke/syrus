require "set"

class JobStackResolver
  STACK_BLOCK_REASON = "stack_dependencies_not_ready"
  FAN_IN_BLOCK_REASON = "stack_fan_in_base_unavailable"

  Result = Data.define(:ready, :reason, :parent, :blocker, :artifacts) do
    def ready? = ready
  end

  def initialize(job, workflow: nil, prepared_base_builder: nil)
    @job = job
    @workflow = workflow
    @prepared_base_builder = prepared_base_builder
  end

  def ready?
    resolve!.ready?
  end

  def resolve!(apply: true)
    @apply = apply
    return force_main! if @job.stack_base_forces_main?
    return ready_result(@job.parent_job) if @job.dependencies_overridden_at.present?

    dependencies = @job.dependencies.includes(:depends_on_job).to_a
    return update_parent!(@job.parent_job) if dependencies.empty? && parent_branch_ready?(@job.parent_job)
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
      return update_parent!(parent) if parent

      return fan_in_result(open_unmerged)
    end

    return blocked_result(STACK_BLOCK_REASON, pending_blocker(unresolved)) if unresolved.any?(&:pending?)
    return blocked_result(STACK_BLOCK_REASON, missing_job_blocker(unresolved)) if unresolved.any? { |dependency| dependency.depends_on_job_id.blank? }

    parent = stack_parent_for(unresolved)
    return blocked_result(STACK_BLOCK_REASON, fan_in_blocker(unresolved.map(&:depends_on_job).compact)) unless parent
    return blocked_result(STACK_BLOCK_REASON, parent_not_ready_blocker(parent)) unless parent_ready?(parent)

    update_parent!(parent)
  end

  private

  def force_main!
    update_parent!(nil)
  end

  def update_parent!(parent)
    parent_id = parent&.id
    return ready_result(parent) if @job.parent_job_id == parent_id
    return ready_result(parent) unless apply?

    old_parent = @job.parent_job
    @job.update!(parent_job: parent)
    refresh_stack_footers(old_parent, parent, @job)
    ready_result(parent)
  end

  def ready_result(parent, artifacts: {})
    Result.new(true, nil, parent, nil, artifacts)
  end

  def blocked_result(reason, blocker)
    Result.new(false, reason, nil, blocker, {})
  end

  def refresh_stack_footers(*jobs)
    jobs.compact.uniq.each do |job|
      PrStackFooter.refresh!(job)
    rescue StandardError => e
      Rails.logger.info("[JobStackResolver] failed to refresh stack footer for #{job.slug}: #{e.class}: #{e.message}")
    end
  end

  def parent_ready?(parent)
    parent_branch_ready?(parent) &&
      parent.head_sha.present?
  end

  def parent_branch_ready?(parent)
    parent&.open? &&
      parent.pr_number.present? &&
      parent.branch_name.present?
  end

  def fan_in_result(dependencies)
    parents = dependencies.map(&:depends_on_job).compact.uniq
    unless prepared_base_eligible?(parents)
      return blocked_result(FAN_IN_BLOCK_REASON, fan_in_blocker(parents))
    end

    build = prepared_base_builder.call(parents)
    return prepared_base_result(build) if build.succeeded?

    blocked_result(FAN_IN_BLOCK_REASON, fan_in_build_failed_blocker(parents, build))
  end

  def prepared_base_eligible?(parents)
    return false unless @workflow
    return false if @job.epic_id.blank?
    return false if parents.size > 1 && parents.any? { |parent| parent.epic_id != @job.epic_id }

    parents.all? do |parent|
      parent.approved? &&
        parent_ready?(parent)
    end
  end

  def prepared_base_builder
    @prepared_base_builder ||= JobStackPreparedBaseBuilder.new(@job, @workflow)
  end

  def prepared_base_result(build)
    @job.update!(parent_job: nil) if apply? && @job.parent_job_id.present?
    artifacts = {
      "prepared_stack_base" => build.to_h
    }
    ready_result(nil, artifacts: artifacts)
  end

  def pending_blocker(unresolved)
    {
      "kind" => "pending_dependency",
      "dependencies" => dependency_payloads(unresolved)
    }
  end

  def missing_job_blocker(unresolved)
    {
      "kind" => "non_job_dependency",
      "dependencies" => dependency_payloads(unresolved)
    }
  end

  def parent_not_ready_blocker(parent)
    {
      "kind" => "stack_parent_not_ready",
      "message" => "selected stack parent is missing an open PR branch or captured head SHA",
      "dependencies" => job_payloads([ parent ])
    }
  end

  def fan_in_blocker(parents)
    {
      "kind" => "fan_in_base_unavailable",
      "message" => "multiple dependency branches are ready, but no single downstream branch contains every required dependency change",
      "dependencies" => job_payloads(parents)
    }
  end

  def fan_in_build_failed_blocker(parents, build)
    fan_in_blocker(parents).merge(
      "build" => build.to_h,
      "action" => "Land the sibling dependencies, linearize the stack, or resolve merge conflicts before retrying."
    )
  end

  def dependency_payloads(dependencies)
    dependencies.map do |dependency|
      target = dependency.depends_on_job
      {
        "dependency_id" => dependency.id,
        "job_id" => target&.id,
        "branch_name" => target&.branch_name,
        "state" => target&.state,
        "pending" => dependency.pending?,
        "unresolved_ref" => dependency.pending? ? dependency.unresolved_slug : nil
      }.compact
    end
  end

  def job_payloads(jobs)
    jobs.map do |job|
      {
        "job_id" => job.id,
        "slug" => job.slug,
        "branch_name" => job.branch_name,
        "state" => job.state,
        "pr_number" => job.pr_number || job.external_pr_number,
        "head_sha" => job.head_sha
      }.compact
    end
  end

  def apply?
    @apply != false
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
