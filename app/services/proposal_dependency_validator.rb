class ProposalDependencyValidator
  def self.validate!(target, satisfaction_mode: "success", required_deployment_stage_name: nil, dependent_job: nil)
    new(
      target,
      satisfaction_mode: satisfaction_mode,
      required_deployment_stage_name: required_deployment_stage_name,
      dependent_job: dependent_job
    ).validate!
  end

  def initialize(target, satisfaction_mode: "success", required_deployment_stage_name: nil, dependent_job: nil)
    @target = target
    @satisfaction_mode = satisfaction_mode.presence || "success"
    @required_deployment_stage_name = required_deployment_stage_name
    @dependent_job = dependent_job
  end

  def validate!
    return unless target
    validate_dependency_shape!
    return unless terminal?
    return if dependency_succeeded?

    raise ArgumentError, invalid_message
  end

  private

  attr_reader :target, :satisfaction_mode, :required_deployment_stage_name, :dependent_job

  def validate_dependency_shape!
    unless JobDependency::SATISFACTION_MODES.include?(satisfaction_mode)
      raise ArgumentError, "satisfaction_mode must be one of: #{JobDependency::SATISFACTION_MODES.join(', ')}"
    end

    dependency = JobDependency.new(
      job: dependent_job,
      source: "manual",
      satisfaction_mode: satisfaction_mode,
      required_deployment_stage_name: required_deployment_stage_name
    )
    if target.is_a?(Job)
      dependency.depends_on_job = target
    elsif target.is_a?(Epic)
      dependency.depends_on_epic = target
    end

    policy = JobDependency::SatisfactionModes.for(dependency)
    policy.validate!
    return if dependency.errors.empty?

    raise ArgumentError, dependency.errors.full_messages.to_sentence
  end

  def terminal?
    target.is_a?(Job) ? target.closed? : target.archived?
  end

  def dependency_succeeded?
    dependency = JobDependency.new(
      job: dependent_job,
      source: "manual",
      satisfaction_mode: satisfaction_mode,
      required_deployment_stage_name: required_deployment_stage_name
    )
    dependency.depends_on_job = target if target.is_a?(Job)
    dependency.depends_on_epic = target if target.is_a?(Epic)
    dependency.dependency_succeeded?
  end

  def invalid_message
    label = target.is_a?(Job) ? App::Presentation.job_slug(target) : App::Presentation.epic_slug(target)
    "Cannot depend on #{label} because it is #{terminal_description} and will not satisfy dependencies."
  end

  def terminal_description
    if target.is_a?(Job)
      "closed as #{target.closure_reason.presence || 'closed'}"
    else
      target.state
    end
  end
end
