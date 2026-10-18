require "rails_helper"

RSpec.describe Throughput::RepositorySnapshot do
  let(:repository) { Factories.repository }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:now) { Time.zone.parse("2026-10-17 12:00:00") }
  let(:contract_payload) do
    { version: Throughput::MetricContract::VERSION, repository_id: repository.id, generated_at: now.iso8601, windows: {} }
  end

  subject(:snapshot) { described_class.new(repository: repository, cache: cache, now: now) }

  it "serves a warm snapshot without recomputing it" do
    cache.write(described_class.snapshot_key(repository.id), contract_payload)
    expect(Throughput::MetricContract).not_to receive(:new)
    expect(snapshot.read).to include(contract_payload.merge(cache_status: "fresh"))
  end

  it "computes and stores one cold-cache fallback" do
    contract = instance_double(Throughput::MetricContract, call: contract_payload)
    expect(Throughput::MetricContract).to receive(:new).with(repository: repository, now: now).once.and_return(contract)
    expect(snapshot.read).to include(cache_status: "computed")
    expect(snapshot.read).to include(cache_status: "fresh")
  end

  it "returns a clearly marked stale snapshot" do
    stale = contract_payload.merge(generated_at: (now - 11.minutes).iso8601)
    cache.write(described_class.snapshot_key(repository.id), stale)
    expect(snapshot.read).to include(cache_status: "stale", generated_at: stale[:generated_at])
  end

  it "retains the prior snapshot when a refresh fails" do
    retained = contract_payload.merge(generated_at: (now - 11.minutes).iso8601)
    cache.write(described_class.snapshot_key(repository.id), retained)
    allow(Throughput::MetricContract).to receive(:new).and_raise("database unavailable")
    expect { snapshot.refresh! }.to raise_error("database unavailable")
    expect(cache.read(described_class.snapshot_key(repository.id))).to eq(retained)
  end

  it "isolates repositories and versions cache keys" do
    other = Factories.repository
    expect(described_class.snapshot_key(repository.id)).not_to eq(described_class.snapshot_key(other.id))
    expect(described_class.snapshot_key(repository.id)).to include("v#{Throughput::MetricContract::VERSION}")
  end

  it "ignores a payload stored under an older contract version" do
    cache.write("throughput:repository_snapshot:v0:repository:#{repository.id}", contract_payload.merge(version: 0))
    contract = instance_double(Throughput::MetricContract, call: contract_payload)
    expect(Throughput::MetricContract).to receive(:new).and_return(contract)

    expect(snapshot.read).to include(version: Throughput::MetricContract::VERSION, cache_status: "computed")
  end

  it "does not duplicate a computation while the repository lock is held" do
    cache.write("#{described_class.snapshot_key(repository.id)}:refreshing", true)
    expect(Throughput::MetricContract).not_to receive(:new)
    expect(snapshot.refresh!).to be_nil
    expect { snapshot.read }.to raise_error(described_class::Unavailable)
  end
end
