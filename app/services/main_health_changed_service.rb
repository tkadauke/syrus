class MainHealthChangedService
  def self.on_health_change!(repository)
    new(repository).on_health_change!
  end

  def initialize(repository)
    @repository = repository
  end

  def on_health_change!
    Rails.logger.warn(
      "[MainHealthChangedService] #{@repository.slug} main_health=#{@repository.main_health} " \
      "ci_health=#{@repository.ci_health} grader_health=#{@repository.grader_health}"
    )
  end
end
