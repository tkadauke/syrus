# Applies a dependency edit that a confirmed `hold_job` carries (requested by
# add/remove/replace_job_dependency with `hold_running: true`). It re-resolves
# every referenced record under the confirming user's visibility, exactly as
# the tools do, and raises ArgumentError so the hold's transaction rolls back
# when the edit is no longer valid.
class JobDependencyEdits
  TOOLS = %w[add_job_dependency remove_job_dependency replace_job_dependency].freeze

  def self.apply!(job:, user:, tool:, arguments:) = new(job:, user:, arguments:).public_send(tool.to_s.delete_suffix("_job_dependency"))

  def initialize(job:, user:, arguments:)
    @job = job
    @user = user
    @arguments = arguments.to_h.stringify_keys
  end

  def add
    if (id = @arguments["depends_on_job_id"])
      dependency = JobDependency.find_or_initialize_by(job: @job, depends_on_job: visible_job!(id))
    else
      dependency = JobDependency.find_or_initialize_by(job: @job, depends_on_epic: visible_epic!(@arguments["depends_on_epic_id"]))
    end
    dependency.source = "manual"
    dependency.created_by_user ||= @user
    dependency.satisfaction_mode = @arguments["satisfaction_mode"].presence || "success"
    dependency.required_deployment_stage_name = @arguments["required_deployment_stage_name"]
    dependency.save!
  end

  def remove
    if (id = @arguments["depends_on_job_id"])
      JobDependency.where(job: @job, depends_on_job: visible_job!(id)).destroy_all
    else
      JobDependency.where(job: @job, depends_on_epic_id: @arguments["depends_on_epic_id"]).destroy_all
    end
  end

  def replace
    removed_job = visible_job!(@arguments["remove_dependency_job_id"])
    added_job = visible_job!(@arguments["add_dependency_job_id"])
    raise ArgumentError, "replacement dependency must be in the same repository" unless added_job.repository_id == @job.repository_id

    removed = @job.dependencies.lock.find_by(depends_on_job: removed_job)
    raise ArgumentError, "Job dependency does not exist: #{removed_job.id}" unless removed

    explicit_mode = @arguments["satisfaction_mode"].presence
    stage = explicit_mode ? @arguments["required_deployment_stage_name"] : (@arguments["required_deployment_stage_name"].presence || removed.required_deployment_stage_name)
    replacement = JobDependency.new(job: @job, depends_on_job: added_job, source: "manual", created_by_user: @user,
      satisfaction_mode: explicit_mode || removed.satisfaction_mode, required_deployment_stage_name: stage)
    replacement.validate!
    removed.destroy!
    replacement.save!
  end

  private

  def visible_job!(id)
    scope = @user.admin? ? Job.visible_to(@user, scope: Job.all) : Job.visible_to(@user)
    scope.find_by(id: id) || raise(ArgumentError, "job not found: #{id}")
  end

  def visible_epic!(id)
    scope = @user.admin? ? Epic.all : Epic.accessible_to(@user)
    scope.find_by(id: id) || raise(ArgumentError, "epic not found: #{id}")
  end
end
