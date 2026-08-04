require "rails_helper"

RSpec.describe CiRepair::CheckRefresh do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "implemented", pr_number: 7) }
  let(:sha) { "abc1234567890000000000000000000000000000" }
  let(:client) { instance_double(GithubClient) }

  before do
    pr = double("PullRequest", head: double("Head", sha: sha))
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    allow(client).to receive(:pull_request).with("acme/widgets", 7, bypass_cache: true).and_return(pr)
  end

  it "updates cached check state and returns failing check details" do
    allow(client).to receive(:check_runs_detail_for).with("acme/widgets", sha).and_return(
      pending?: false,
      any_failed?: true,
      all_passed?: false,
      failed_checks: [
        { name: "build", conclusion: "failure", summary: "failed", html_url: "https://github.com/checks/1" }
      ]
    )

    result = described_class.call(job)

    expect(job.reload).to have_attributes(pr_checks_sha: sha, pr_checks_state: "failing")
    expect(result.payload).to include(job_id: job.id, head_sha: sha, pr_checks_state: "failing")
    expect(result.payload.fetch(:failing_checks)).to include(
      include(name: "build", details_url: "https://github.com/checks/1")
    )
  end
end
