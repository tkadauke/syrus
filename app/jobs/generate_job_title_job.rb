class GenerateJobTitleJob < ApplicationJob
  TitleGenerationFailed = Class.new(StandardError)

  PENDING_TITLE = "Generating title..."
  FALLBACK_TITLE = "Untitled job"

  queue_as :low_priority_maintenance

  def perform(job)
    return unless job.title_pending?

    result = DirectJobTitleGenerator.generate(
      job.issue_body.to_s,
      user: job.user,
      repository: job.repository,
      agent_provider: job.agent_provider
    )
    raise TitleGenerationFailed, result.error unless result.success?

    title = result.title
    job.update!(issue_title: title, title_pending: false)
  rescue => e
    clear_pending_title(job)
    raise e
  end

  private

  def clear_pending_title(job)
    return unless job&.persisted?

    job.update!(
      issue_title: fallback_title_for(job),
      title_pending: false
    )
  end

  def fallback_title_for(job)
    title = job.issue_title.to_s.strip
    return title if title.present? && title != PENDING_TITLE

    FALLBACK_TITLE
  end
end
