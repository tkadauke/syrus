class GenerateJobTitleJob < ApplicationJob
  TitleGenerationFailed = Class.new(StandardError)

  PENDING_TITLE = "Generating title..."
  FALLBACK_TITLE = "Untitled job"

  queue_as :default

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
    broadcast_title_update(job)
  rescue => e
    clear_pending_title(job)
    raise e
  end

  private

  def clear_pending_title(job)
    return unless job&.persisted?

    job.update_columns(
      issue_title: fallback_title_for(job),
      title_pending: false,
      updated_at: Time.current
    )
    broadcast_title_update(job)
  end

  def fallback_title_for(job)
    title = job.issue_title.to_s.strip
    return title if title.present? && title != PENDING_TITLE

    FALLBACK_TITLE
  end

  def broadcast_title_update(job)
    AppEvents.broadcast(user: job.user, type: "updated", resource: "job", id: job.id, changed: [ "issue_title", "title_pending" ])
  end
end
