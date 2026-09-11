require "rails_helper"

RSpec.describe GithubApiUsageRollup do
  it "coalesces repeated calls into one hourly credential/operation bucket" do
    user = Factories.user
    repo = Factories.repository(user: user, owner: "acme", name: "widgets")
    headers = {
      "x-ratelimit-resource" => "core",
      "x-ratelimit-remaining" => "4999",
      "x-ratelimit-limit" => "5000",
      "x-ratelimit-reset" => 1.hour.from_now.to_i.to_s
    }

    2.times do
      described_class.record!(
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
    end

    rollup = described_class.sole
    expect(rollup.request_count).to eq(2)
    expect(rollup.rate_limited_count).to eq(0)
    expect(rollup.credential_key).to eq("user:#{user.id}")
    expect(rollup.repository_key).to eq("repository:#{repo.id}")
  end
end
