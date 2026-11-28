require "rails_helper"

RSpec.describe FailureProblems::GithubApi do
  def octokit_error(status, body: "", method: :post, url: "https://api.github.com/repos/acme/widgets/pulls")
    Octokit::Error.from_response(
      method: method,
      url: url,
      status: status,
      response_headers: { "content-type" => "application/json" },
      body: body
    )
  end

  it "declares every 5xx a retryable GitHub outage, including the 504 Octokit has no class for" do
    [ 500, 502, 503, 504 ].each do |status|
      error = octokit_error(status)
      problem = described_class.for(error)

      expect(problem.code).to eq("github_api_transient"), "status #{status} (#{error.class})"
      expect(problem).to be_retryable
      expect(problem.evidence).to include(http_status: status)
    end
  end

  it "declares primary and secondary rate limits as GitHub rate limiting" do
    primary = octokit_error(403, body: { message: "API rate limit exceeded for installation ID 1." }.to_json)
    secondary = octokit_error(403, body: { message: "You have exceeded a secondary rate limit." }.to_json)
    abuse = octokit_error(403, body: { message: "You have triggered an abuse detection mechanism." }.to_json)
    too_many = octokit_error(429)

    [ primary, secondary, abuse, too_many ].each do |error|
      expect(described_class.for(error).code).to eq("github_api_rate_limited"), error.class.name
    end
    expect(described_class.for(primary)).to be_retryable
  end

  it "declares a 404 and a 422 non-retryable" do
    not_found = described_class.for(octokit_error(404, method: :get))
    unprocessable = described_class.for(octokit_error(422, body: { message: "Validation Failed" }.to_json))

    expect(not_found.code).to eq("github_api_rejected")
    expect(not_found).not_to be_retryable
    expect(unprocessable.code).to eq("github_api_rejected")
    expect(unprocessable).not_to be_retryable
  end

  it "keeps the no-commits-between PR refusal on its retryable checkpoint path" do
    error = octokit_error(422, body: { message: "Validation Failed", errors: [ { message: "No commits between main and feature" } ] }.to_json)

    expect(described_class.for(error).code).to eq("pr_open_no_commits_between")
  end

  it "never declares a GitHub failure as the agent provider's" do
    codes = [ 500, 403, 404, 422 ].map { |status| described_class.for(octokit_error(status)).code }

    expect(codes).not_to include("provider_transient", "rate_limited")
  end
end
