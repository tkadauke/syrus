require "rails_helper"

RSpec.describe Throughput::Callbacks do
  include ActiveJob::TestHelper

  let(:now) { Time.zone.local(2026, 7, 31, 12, 0, 0) }

  around { |example| travel_to(now) { example.run } }

  it "enqueues refreshes for active repositories even when polling is disabled" do
    polled = Factories.repository
    visible_without_polling = Factories.repository
    visible_without_polling.update!(polling_enabled: false)

    expect { described_class.on_tick }
      .to have_enqueued_job(Throughput::RefreshRepositorySnapshotJob).with(polled.id).exactly(:once)
      .and have_enqueued_job(Throughput::RefreshRepositorySnapshotJob).with(visible_without_polling.id).exactly(:once)
  end

  it "does not enqueue a repository whose cached snapshot is fresh" do
    repository = Factories.repository
    allow(Rails.cache).to receive(:read)
      .with(Throughput::RepositorySnapshot.snapshot_key(repository.id))
      .and_return({ generated_at: (now - 1.minute).iso8601 })

    expect { described_class.on_tick }
      .not_to have_enqueued_job(Throughput::RefreshRepositorySnapshotJob).with(repository.id)
  end

  it "enqueues a repository whose cached snapshot is stale" do
    repository = Factories.repository
    allow(Rails.cache).to receive(:read)
      .with(Throughput::RepositorySnapshot.snapshot_key(repository.id))
      .and_return({ generated_at: (now - 11.minutes).iso8601 })

    expect { described_class.on_tick }
      .to have_enqueued_job(Throughput::RefreshRepositorySnapshotJob).with(repository.id).exactly(:once)
  end
end
