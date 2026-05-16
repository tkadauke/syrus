class GithubAppWebhooksController < ActionController::Base
  def create
    handle_pull_request_review if request.headers["X-GitHub-Event"] == "pull_request_review"

    head :ok
  end

  private

  def handle_pull_request_review
    payload = JSON.parse(request.raw_post)
    review = payload["review"] || {}
    return unless review["state"].to_s.downcase == "approved"

    repository = payload["repository"] || {}
    owner = repository.dig("owner", "login")
    name = repository["name"]
    pr_number = payload.dig("pull_request", "number")
    return if owner.blank? || name.blank? || pr_number.blank?

    approved_at = parse_time(review["submitted_at"]) || Time.current
    evidence_url = review["html_url"]

    Repository.where(owner: owner, name: name).find_each do |repo|
      repo.jobs.where(pr_number: pr_number)
          .or(repo.jobs.where(external_pr_number: pr_number))
          .find_each do |job|
        job.record_github_review_approval!(
          approved_at: approved_at,
          review_url: evidence_url
        )
      end
    end
  rescue JSON::ParserError
    nil
  end

  def parse_time(value)
    Time.zone.parse(value) if value.present?
  rescue ArgumentError
    nil
  end
end
