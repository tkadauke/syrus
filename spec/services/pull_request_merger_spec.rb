require "rails_helper"

RSpec.describe PullRequestMerger do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main")
  end

  it "delegates to GithubClient#merge_pull_request with a rebase merge by default" do
    merge_result = double(merged: true, sha: "abc123")
    fake_client = instance_double(GithubClient, merge_pull_request: merge_result)

    merger = described_class.new(repository, client: fake_client)
    result = merger.merge(pr_number: 7, commit_title: "Merge acme/widgets#7 via Syrus")

    expect(result).to eq(merge_result)
    expect(fake_client).to have_received(:merge_pull_request).with(
      "acme/widgets",
      7,
      commit_title: "Merge acme/widgets#7 via Syrus",
      merge_method: "rebase"
    )
  end

  it "allows overriding the merge method" do
    fake_client = instance_double(GithubClient, merge_pull_request: double(merged: true))

    described_class.new(repository, client: fake_client).merge(
      pr_number: 7,
      commit_title: "Merge acme/widgets#7 via Syrus",
      merge_method: "squash"
    )

    expect(fake_client).to have_received(:merge_pull_request).with(
      "acme/widgets",
      7,
      commit_title: "Merge acme/widgets#7 via Syrus",
      merge_method: "squash"
    )
  end

  it "propagates GitHub errors instead of swallowing them, leaving retry/rescue policy to the caller" do
    fake_client = instance_double(GithubClient)
    allow(fake_client).to receive(:merge_pull_request).and_raise(Octokit::Conflict.new(status: 409, body: { message: "conflict" }))

    expect do
      described_class.new(repository, client: fake_client).merge(pr_number: 7, commit_title: "Merge acme/widgets#7 via Syrus")
    end.to raise_error(Octokit::Conflict)
  end
end
