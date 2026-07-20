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
end
