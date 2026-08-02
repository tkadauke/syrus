class ProposalDependencyValidator
  def self.validate!(target)
    new(target).validate!
  end

  def initialize(target)
    @target = target
  end

  def validate!
    return unless target
    return unless terminal?
    return if dependency_succeeded?

    raise ArgumentError, invalid_message
  end

  private

  attr_reader :target

  def terminal?
    target.is_a?(Job) ? target.closed? : target.archived?
  end

  def dependency_succeeded?
    case target
    when Job
      target.dependency_succeeded?
    when Epic
      target.done?
    else
      true
    end
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
