require "rails_helper"

RSpec.describe Throughput::RefreshRepositorySnapshotJob do
  it "runs refreshes on the polling queue" do
    expect(described_class.queue_name).to eq("polling")
  end

  it "refreshes an active polled repository" do
    repository = Factories.repository
    snapshot = instance_double(Throughput::RepositorySnapshot, refresh!: true)
    expect(Throughput::RepositorySnapshot).to receive(:new).with(repository: repository).and_return(snapshot)
    described_class.perform_now(repository.id)
  end

  it "skips repositories excluded from polling" do
    repository = Factories.repository
    repository.update!(polling_enabled: false)
    expect(Throughput::RepositorySnapshot).not_to receive(:new)
    described_class.perform_now(repository.id)
  end
end
