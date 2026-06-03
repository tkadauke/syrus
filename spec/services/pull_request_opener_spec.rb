require "rails_helper"

RSpec.describe PullRequestOpener do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main")
  end

  it "delegates to GithubClient#create_pull_request and returns the new PR number" do
    fake_pr = double(number: 99)
    fake_client = instance_double(GithubClient, create_pull_request: fake_pr)

    opener = described_class.new(repository, client: fake_client)
    pr_number = opener.open(branch: "syrus/issue-1-1", title: "T", body: "B")

    expect(pr_number).to eq(99)
    expect(fake_client).to have_received(:create_pull_request).with(
      "acme/widgets",
      base: "main",
      head: "acme:syrus/issue-1-1",
      title: "T",
      body: "B"
    )
  end

  it "uses the Job's effective base branch while keeping the PR in the configured repository" do
    parent = Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 1,
      state: "queued",
      branch_name: "syrus/issue-1",
      pr_number: 1
    )
    job = Factories.job_record(user: user, repository: repository, issue_number: 2, state: "queued")
    JobDependency.create!(job: job, depends_on_job: parent, source: "manual", created_by_user: user)
    fake_pr = double(number: 100)
    fake_client = instance_double(GithubClient, create_pull_request: fake_pr)

    opener = described_class.new(repository, client: fake_client)
    pr_number = opener.open(branch: "syrus/issue-2-2", title: "T", body: "B", job: job)

    expect(pr_number).to eq(100)
    expect(fake_client).to have_received(:create_pull_request).with(
      "acme/widgets",
      base: "syrus/issue-1",
      head: "acme:syrus/issue-2-2",
      title: "T",
      body: "B"
    )
  end

  it "qualifies the head branch with the configured repository owner" do
    fork = Factories.repository(user: user, owner: "octavia", name: "widgets", default_branch: "main")
    fake_pr = double(number: 101)
    fake_client = instance_double(GithubClient, create_pull_request: fake_pr)

    opener = described_class.new(fork, client: fake_client)
    pr_number = opener.open(branch: "syrus/issue-3-3", title: "T", body: "B")

    expect(pr_number).to eq(101)
    expect(fake_client).to have_received(:create_pull_request).with(
      "octavia/widgets",
      base: "main",
      head: "octavia:syrus/issue-3-3",
      title: "T",
      body: "B"
    )
  end
end
