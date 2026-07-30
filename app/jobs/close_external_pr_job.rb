class CloseExternalPrJob < ApplicationJob
  queue_as :default

  CLOSE_COMMENT = "This PR was closed because the associated Syrus Job was closed.".freeze

  def perform(job_id)
    @job = Job.find_by(id: job_id)
    return unless @job&.closed? && @job.external_pr? && @job.external_pr_number.present?

    @client = GithubClient.for(repository: @job.repository, user: @job.user)
    @slug   = @job.repository.slug
    @pr     = @client.pull_request(@slug, @job.external_pr_number)

    return if @pr.merged || @pr.state == "closed"

    @client.close_pull_request(@slug, @job.external_pr_number)
    @client.add_issue_comment(@slug, @job.external_pr_number, CLOSE_COMMENT)
  rescue => e
    Rails.logger.warn("[CloseExternalPrJob] failed to close GitHub PR #{@job&.repository&.slug}##{@job&.external_pr_number}: #{e.message}")
  end
end
