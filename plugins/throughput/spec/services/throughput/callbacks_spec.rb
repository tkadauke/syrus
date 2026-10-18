require "rails_helper"

RSpec.describe Throughput::Callbacks do
  include ActiveJob::TestHelper

  it "enqueues refreshes for active repositories even when polling is disabled" do
    polled = Factories.repository
    visible_without_polling = Factories.repository
    visible_without_polling.update!(polling_enabled: false)

    expect { described_class.on_tick }
      .to have_enqueued_job(Throughput::RefreshRepositorySnapshotJob).with(polled.id).exactly(:once)
      .and have_enqueued_job(Throughput::RefreshRepositorySnapshotJob).with(visible_without_polling.id).exactly(:once)
  end
end
