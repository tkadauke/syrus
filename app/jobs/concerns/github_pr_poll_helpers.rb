module GithubPrPollHelpers
  extend ActiveSupport::Concern

  private

  # Octokit returns Sawyer::Resource objects; serialize to a plain
  # hash that round-trips through Workflow.artifacts (JSON column).
  def serialize_comment(c)
    {
      "author"     => c.user&.login,
      "body"       => c.body,
      "path"       => (c.respond_to?(:path) ? c.path : nil),
      "line"       => (c.respond_to?(:line) ? c.line : nil),
      "diff_hunk"  => (c.respond_to?(:diff_hunk) ? c.diff_hunk : nil),
      "created_at" => c.created_at&.iso8601
    }
  end

  def reject_syrus_bot_comments(comments)
    comments.reject { |comment| syrus_bot_comment?(comment) }
  end

  def syrus_bot_comment?(comment)
    user = comment.respond_to?(:user) ? comment.user : nil
    login = github_resource_value(user, :login).to_s.strip.downcase
    type = github_resource_value(user, :type).to_s.strip.downcase
    app_slug = AppSetting.current.github_app_slug.to_s.strip.downcase
    return false if login.blank? || app_slug.blank?

    bot_login = "#{app_slug.delete_suffix("[bot]")}[bot]"
    login == bot_login || (type == "bot" && login == app_slug)
  end

  def review_submitted_at(review)
    value = review.respond_to?(:submitted_at) ? review.submitted_at : nil
    return value if value.respond_to?(:to_time) && !value.is_a?(String)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  # Same-repo head means we have push access via the operator's
  # github_token. Forks would need maintainer-edits opt-in and a
  # different push URL.
  def we_control_head?(pr)
    pr.head&.repo&.full_name == pr.base&.repo&.full_name
  end

  def github_resource_value(resource, key)
    return unless resource
    return resource.public_send(key) if resource.respond_to?(key)
    if resource.respond_to?(:[]) && resource.respond_to?(:key?)
      return resource[key] if resource.key?(key)
      return resource[key.to_s] if resource.key?(key.to_s)
    end

    nil
  end
end
