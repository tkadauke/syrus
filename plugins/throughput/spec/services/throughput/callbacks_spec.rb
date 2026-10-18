require "rails_helper"

RSpec.describe Throughput::Callbacks do
  include ActiveJob::TestHelper

  it "enqueues refreshes only for active repositories that are polled" do
    included = Factories.repository
    excluded = Factories.repository
    excluded.update!(polling_enabled: false)

    expect { described_class.on_tick }
      .to have_enqueued_job(Throughput::RefreshRepositorySnapshotJob).with(included.id).exactly(:once)
    expect(enqueued_jobs).not_to include(hash_including(args: [ excluded.id ]))
  end
end
