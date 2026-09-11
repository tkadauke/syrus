require "rails_helper"

RSpec.describe GithubSource::ApiUsagePayload do
  it "groups GitHub API usage by operation and repository" do
    user = Factories.user
    repo = Factories.repository(user: user, owner: "acme", name: "widgets")
    headers = {
      "x-ratelimit-resource" => "core",
      "x-ratelimit-remaining" => "42",
      "x-ratelimit-limit" => "5000",
      "x-ratelimit-reset" => 1.hour.from_now.to_i.to_s
    }
    GithubApiUsageRollup.record!(
      auth_source: :pat,
      installation: nil,
      user: user,
      repository: repo,
      repo_slug: repo.slug,
      operation: "pull_request",
      headers: headers,
      status: 200,
      rate_limited: false
    )

    payload = described_class.new(params: { hours: 24 }).as_json

    expect(payload[:totals]).to include(requests: 1, rate_limited: 0)
    expect(payload[:by_operation].first).to include(auth_source: "pat", operation: "pull_request", requests: 1)
    expect(payload[:by_repository].first).to include(auth_source: "pat", repo_slug: repo.slug, requests: 1)
  end
end
