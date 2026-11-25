class Coworkers::EnvironmentSource::Invalid < StandardError
  attr_reader :errors

  def initialize(errors)
    @errors = Array(errors)
    super(@errors.join("; "))
  end
end
