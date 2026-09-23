require "rails_helper"

RSpec.describe PollHotfixSyncJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:content) { instance_double(RepositoryContent::Reader) }

  before do
    allow(RepositoryContent).to receive(:for).with(repository, user: user).and_return(content)
    allow(content).to receive(:resolve) { |ref, **| RepositoryContent::Revision.new(id: ref) }
    allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(
      instance_double(DeliveryPolicy, hotfix_sync_enabled?: true, hotfix_sync_source_branch: "main", hotfix_sync_target_branch: "develop")
    )
  end

  it "does nothing for an unknown repository id" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  it "does nothing for an archived repository" do
    repository.archive!

    expect(RepositoryContent).not_to receive(:for)
    described_class.perform_now(repository.id)
  end

  it "does nothing when hotfix sync is not enabled" do
    allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(
      instance_double(DeliveryPolicy, hotfix_sync_enabled?: false)
    )

    expect(RepositoryContent).not_to receive(:for)
    described_class.perform_now(repository.id)
  end

  it "does nothing when the source and target branches resolve to the same branch" do
    allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(
      instance_double(DeliveryPolicy, hotfix_sync_enabled?: true, hotfix_sync_source_branch: "main", hotfix_sync_target_branch: "main")
    )

    expect(RepositoryContent).not_to receive(:for)
    described_class.perform_now(repository.id)
  end

  it "does nothing when a hotfix sync is already pending for this repository" do
    allow(HotfixSyncDispatcher).to receive(:pending_for?).with(repository).and_return(true)

    expect(RepositoryContent).not_to receive(:for)
    described_class.perform_now(repository.id)
  end

  it "does nothing when the development branch already contains the release branch's tip" do
    allow(content).to receive(:relation).and_return(:identical)

    expect(HotfixSyncDispatcher).not_to receive(:call!)
    described_class.perform_now(repository.id)
  end

  it "does nothing when the release branch is behind the development branch" do
    allow(content).to receive(:relation).and_return(:behind)

    expect(HotfixSyncDispatcher).not_to receive(:call!)
    described_class.perform_now(repository.id)
  end

  it "dispatches a hotfix sync when the release branch has commits missing from the development branch" do
    allow(content).to receive(:relation)
      .with(base: RepositoryContent::Revision.new(id: "develop"), head: RepositoryContent::Revision.new(id: "main"))
      .and_return(:ahead)
    allow(HotfixSyncDispatcher).to receive(:call!)

    described_class.perform_now(repository.id)

    expect(HotfixSyncDispatcher).to have_received(:call!).with(repository: repository, source_branch: "main", target_branch: "develop")
  end

  it "dispatches a hotfix sync when the branches have diverged" do
    allow(content).to receive(:relation).and_return(:diverged)
    allow(HotfixSyncDispatcher).to receive(:call!)

    described_class.perform_now(repository.id)

    expect(HotfixSyncDispatcher).to have_received(:call!).with(repository: repository, source_branch: "main", target_branch: "develop")
  end

  it "does not raise when the repository content provider is unavailable" do
    allow(content).to receive(:relation).and_raise(RepositoryContent::Unavailable.new("rate limited"))
    expect(HotfixSyncDispatcher).not_to receive(:call!)

    expect { described_class.perform_now(repository.id) }.not_to raise_error
  end

  it "does nothing when a branch has not reached the mirror or host yet" do
    allow(content).to receive(:resolve).with("main").and_raise(RepositoryContent::UnknownRevision.new("unknown"))
    expect(HotfixSyncDispatcher).not_to receive(:call!)

    expect { described_class.perform_now(repository.id) }.not_to raise_error
  end
end
