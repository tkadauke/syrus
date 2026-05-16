class GithubAppWebhooksController < ActionController::Base
  def create
    handle_pull_request_review if request.headers["X-GitHub-Event"] == "pull_request_review"
    process_issue_edited if request.headers["X-GitHub-Event"] == "issues"
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

  def process_issue_edited
    payload = JSON.parse(request.raw_post)
    return unless payload["action"] == "edited"

    repository_payload = payload["repository"].to_h
    owner = repository_payload.dig("owner", "login").presence || repository_payload["full_name"].to_s.split("/").first
    name = repository_payload["name"].presence || repository_payload["full_name"].to_s.split("/").last
    issue = payload["issue"].to_h
    old_body = payload.dig("changes", "body", "from").to_s
    new_body = issue["body"].to_s

    Repository.where("LOWER(owner) = ? AND LOWER(name) = ?", owner.to_s.downcase, name.to_s.downcase).find_each do |repository|
      old_marker = EpicMarkerParser.parse(text: old_body, default_repository: repository)
      new_marker = EpicMarkerParser.parse(text: new_body, default_repository: repository)

      if old_marker && new_marker.nil?
        Rails.logger.warn("[GithubAppWebhooksController] #{repository.slug}##{issue["number"]} Epic marker removed; existing Epic/Job links left unchanged")
      elsif old_marker.nil? && new_marker
        Rails.logger.info("[GithubAppWebhooksController] #{repository.slug}##{issue["number"]} Epic marker added")
      elsif old_marker && new_marker && old_marker != new_marker
        Rails.logger.info("[GithubAppWebhooksController] #{repository.slug}##{issue["number"]} Epic marker changed")
      end
    end
  rescue JSON::ParserError
    Rails.logger.warn("[GithubAppWebhooksController] invalid JSON payload")
  end
end
