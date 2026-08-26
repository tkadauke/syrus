require "rails_helper"

RSpec.describe PollHotfixSyncJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(
      instance_double(DeliveryPolicy, hotfix_sync_enabled?: true, hotfix_sync_source_branch: "main", hotfix_sync_target_branch: "develop")
    )
  end

  it "does nothing for an unknown repository id" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  it "does nothing for an archived repository" do
    repository.archive!

    expect(client).not_to receive(:compare_commits)
    described_class.perform_now(repository.id)
  end

  it "does nothing when hotfix sync is not enabled" do
    allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(
      instance_double(DeliveryPolicy, hotfix_sync_enabled?: false)
    )

    expect(client).not_to receive(:compare_commits)
    described_class.perform_now(repository.id)
  end

  it "does nothing when the source and target branches resolve to the same branch" do
    allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(
      instance_double(DeliveryPolicy, hotfix_sync_enabled?: true, hotfix_sync_source_branch: "main", hotfix_sync_target_branch: "main")
    )

    expect(client).not_to receive(:compare_commits)
    described_class.perform_now(repository.id)
  end

  it "does nothing when a hotfix sync is already pending for this repository" do
    allow(HotfixSyncDispatcher).to receive(:pending_for?).with(repository).and_return(true)

    expect(client).not_to receive(:compare_commits)
    described_class.perform_now(repository.id)
  end

  it "does nothing when the development branch already contains the release branch's tip" do
    allow(client).to receive(:compare_commits).with(repository.slug, "develop", "main").and_return(
      { commits: [], merge_base_sha: "abc123", status: "identical" }
    )

    expect(HotfixSyncDispatcher).not_to receive(:call!)
    described_class.perform_now(repository.id)
  end

  it "dispatches a hotfix sync when the release branch has commits missing from the development branch" do
    allow(client).to receive(:compare_commits).with(repository.slug, "develop", "main").and_return(
      { commits: [ { sha: "deadbeef", short_sha: "deadbee", message: "urgent fix", date: Time.current } ], merge_base_sha: "abc123", status: "ahead" }
    )
    allow(HotfixSyncDispatcher).to receive(:call!)

    described_class.perform_now(repository.id)

    expect(HotfixSyncDispatcher).to have_received(:call!).with(repository: repository, source_branch: "main", target_branch: "develop")
  end

  it "does not raise when GitHub is transiently unreachable" do
    allow(client).to receive(:compare_commits).and_raise(Faraday::ConnectionFailed.new("boom"))
    expect(HotfixSyncDispatcher).not_to receive(:call!)

    expect { described_class.perform_now(repository.id) }.not_to raise_error
  end
end
