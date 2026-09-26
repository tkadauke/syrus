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

  it "exposes operational filter schema fields and applies representative filters" do
    user = Factories.user
    repo = Factories.repository(user: user, owner: "acme", name: "widgets")
    headers = {
      "x-ratelimit-resource" => "search",
      "x-ratelimit-remaining" => "0",
      "x-ratelimit-limit" => "30",
      "x-ratelimit-reset" => 1.hour.from_now.to_i.to_s
    }
    GithubApiUsageRollup.record!(
      auth_source: :pat,
      installation: nil,
      user: user,
      repository: repo,
      repo_slug: repo.slug,
      operation: "issues",
      headers: headers,
      status: 403,
      rate_limited: true
    )
    GithubApiUsageRollup.record!(
      auth_source: :app,
      installation: nil,
      user: nil,
      repository: nil,
      repo_slug: "other/repo",
      operation: "contents",
      headers: headers.merge("x-ratelimit-remaining" => "12"),
      status: 200,
      rate_limited: false
    )

    payload = described_class.new(params: {
      hours: 24,
      operation: "issues",
      resource: "search",
      auth_source: "pat",
      credential_key: "user:#{user.id}",
      repository_id: repo.id,
      repo_slug: "acme/widgets",
      user_id: user.id,
      status: 403,
      rate_limited: "true"
    }).as_json

    expect(payload[:filter_schema].map { |field| field[:field] }).to include(
      "operation",
      "resource",
      "auth_source",
      "credential_key",
      "repository_id",
      "repo_slug",
      "user_id",
      "installation_id",
      "status",
      "rate_limited",
      "bucket_since",
      "last_seen_since"
    )
    expect(payload[:totals]).to eq(requests: 1, rate_limited: 1)
    expect(payload[:by_operation]).to contain_exactly(include(
      auth_source: "pat",
      credential_key: "user:#{user.id}",
      operation: "issues",
      resource: "search",
      last_status: 403,
      last_limit: 30
    ))
  end
end
