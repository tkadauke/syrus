class MainConcernAggregator
  WINDOW_MINUTES = 30

  def self.check!(repository)
    new(repository).check!
  end

  def initialize(repository)
    @repository = repository
  end

  def check!
    return if @repository.main_health_broken?

    count = MainConcernReport
      .for_repository_since(@repository, WINDOW_MINUTES.minutes.ago)
      .count

    return if count < AppSetting.main_concern_report_threshold

    Rails.logger.warn(
      "[MainConcernAggregator] #{@repository.slug} crowd quorum reached " \
      "(#{count} reports in #{WINDOW_MINUTES}m) — marking grader_health broken"
    )

    @repository.update!(grader_health: "broken")
    MainHealthChangedService.on_health_change!(@repository)
  end
end
