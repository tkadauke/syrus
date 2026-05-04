class PollExternalPrJob < ApplicationJob
  queue_as :default

  # One concurrent poll per Job — prevents races on the closure write.
  limits_concurrency to: 1, key: ->(job_id, *) { "external_pr_poll:#{job_id}" }

  def perform(job_id)
    @job = Job.find_by(id: job_id)
    return unless @job&.open? && @job.external_pr_number.present? && @job.pr_number.blank?
    return if @job.repository.archived?

    @client = GithubClient.for(@job.user)
    @slug = @job.repository.slug
    @pr = @client.pull_request(@slug, @job.external_pr_number)

    return close_with("external_pr_merged") if @pr.merged
    close_with("external_pr_closed") if @pr.state == "closed"
  end

  private

  def close_with(reason)
    Rails.logger.info("[PollExternalPrJob] closing job #{@job.id}: #{reason}")
    @job.runs.active.find_each do |r|
      r.cancel! if r.may_cancel?
      r.save!
    end
    @job.close_with_reason!(reason)
  end
end
