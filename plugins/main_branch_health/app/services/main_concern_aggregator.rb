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

    sha = @repository.last_health_checked_sha.to_s.presence
    return unless sha

    if conclusive_healthy_grader_result_exists?(sha)
      Rails.logger.info(
        "[MainConcernAggregator] #{@repository.slug}@#{sha} already has a conclusive healthy " \
        "main-grader result; ignoring concern quorum"
      )
      return
    end

    reports = MainConcernReport
      .for_repository_since(@repository, WINDOW_MINUTES.minutes.ago)
      .for_observed_sha(sha)

    count = reports.count

    return if count < AppSetting.main_concern_report_threshold

    Rails.logger.warn(
      "[MainConcernAggregator] #{@repository.slug} crowd quorum reached " \
      "(#{count} reports in #{WINDOW_MINUTES}m) — marking grader_health broken"
    )

    failed_names = reports.flat_map { |report| Array(report.failing_tests) }.compact_blank.uniq.presence
    MainBranchHealthCheck.record_concern_quorum(
      repository: @repository,
      sha: sha,
      grader_failed_names: failed_names
    )
    @repository.update!(grader_health: "broken")
    MainHealthChangedService.on_health_change!(@repository)
  end

  private

  def conclusive_healthy_grader_result_exists?(sha)
    MainBranchHealthCheck.exists?(
      repository: @repository,
      sha: sha,
      source: "grader_workflow",
      grader_health: "healthy"
    )
  end
end
