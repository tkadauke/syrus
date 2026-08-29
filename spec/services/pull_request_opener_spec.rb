require "rails_helper"

RSpec.describe PullRequestOpener do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main")
  end

  it "delegates to GithubClient#create_pull_request and returns the new PR number" do
    fake_pr = double(number: 99)
    fake_client = instance_double(GithubClient, create_pull_request: fake_pr, open_pull_request_for_head: nil)

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

  it "returns an already-open PR for the same head and base instead of creating another one" do
    existing_pr = double(number: 88)
    fake_client = instance_double(GithubClient, create_pull_request: nil, open_pull_request_for_head: existing_pr)

    opener = described_class.new(repository, client: fake_client)
    pr_number = opener.open(branch: "syrus/issue-1-1", title: "T", body: "B")

    expect(pr_number).to eq(88)
    expect(fake_client).not_to have_received(:create_pull_request)
  end

  it "recovers from GitHub's already-exists validation by attaching the existing PR" do
    error = Octokit::UnprocessableEntity.new(
      method: :post,
      url: "https://api.github.com/repos/acme/widgets/pulls",
      status: 422,
      body: "Validation Failed: A pull request already exists for acme:syrus/issue-1-1."
    )
    existing_pr = double(number: 89)
    fake_client = instance_double(GithubClient)
    allow(fake_client).to receive(:open_pull_request_for_head).and_return(nil, existing_pr)
    allow(fake_client).to receive(:create_pull_request).and_raise(error)

    opener = described_class.new(repository, client: fake_client)
    pr_number = opener.open(branch: "syrus/issue-1-1", title: "T", body: "B")

    expect(pr_number).to eq(89)
  end

  it "recovers from a transient GitHub create response when the PR was created anyway" do
    error = Octokit::BadGateway.new(
      method: :post,
      url: "https://api.github.com/repos/acme/widgets/pulls",
      status: 502,
      body: "Server Error"
    )
    existing_pr = double(number: 90)
    fake_client = instance_double(GithubClient)
    allow(fake_client).to receive(:open_pull_request_for_head).and_return(nil, existing_pr)
    allow(fake_client).to receive(:create_pull_request).and_raise(error)

    opener = described_class.new(repository, client: fake_client)
    pr_number = opener.open(branch: "syrus/issue-1-1", title: "T", body: "B")

    expect(pr_number).to eq(90)
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
    fake_client = instance_double(GithubClient, create_pull_request: fake_pr, open_pull_request_for_head: nil)

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

  it "uses the Job's target_branch override instead of the repository default or stack resolution" do
    job = Factories.job_record(user: user, repository: repository, issue_number: 5, state: "queued", target_branch: "release/4.2")
    fake_pr = double(number: 103)
    fake_client = instance_double(GithubClient, create_pull_request: fake_pr, open_pull_request_for_head: nil)

    opener = described_class.new(repository, client: fake_client)
    pr_number = opener.open(branch: "syrus/issue-5-5", title: "T", body: "B", job: job)

    expect(pr_number).to eq(103)
    expect(fake_client).to have_received(:create_pull_request).with(
      "acme/widgets",
      base: "release/4.2",
      head: "acme:syrus/issue-5-5",
      title: "T",
      body: "B"
    )
  end

  it "qualifies the head branch with the configured repository owner" do
    fork = Factories.repository(user: user, owner: "octavia", name: "widgets", default_branch: "main")
    fake_pr = double(number: 101)
    fake_client = instance_double(GithubClient, create_pull_request: fake_pr, open_pull_request_for_head: nil)

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

  it "opens a cross-fork PR with the fork owner in head and the upstream slug as base repo" do
    upstream = Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main")
    fork = Factories.repository(user: user, owner: "forker", name: "widgets", default_branch: "main")
    fake_pr = double(number: 102)
    fake_client = instance_double(GithubClient, create_pull_request: fake_pr, open_pull_request_for_head: nil)

    opener = described_class.new(upstream, client: fake_client, head_repository: fork)
    pr_number = opener.open(branch: "syrus/issue-4-4", title: "T", body: "B")

    expect(pr_number).to eq(102)
    expect(fake_client).to have_received(:create_pull_request).with(
      "acme/widgets",
      base: "main",
      head: "forker:syrus/issue-4-4",
      title: "T",
      body: "B"
    )
  end
end
