require "rails_helper"

RSpec.describe RefreshTestIdentitiesJob do
  include ActiveJob::TestHelper

  it "refreshes the requested identities, then indexes them for search" do
    allow(TestInsights::TestIdentity).to receive(:refresh_many!)

    expect { described_class.perform_now([ 3, 3, 7, nil ]) }
      .to have_enqueued_job(IndexTestIdentitiesJob).with([ 3, 7 ]).on_queue("plugin_test_insights")
    expect(TestInsights::TestIdentity).to have_received(:refresh_many!).with([ 3, 7 ])
  end

  it "does nothing without identities" do
    allow(TestInsights::TestIdentity).to receive(:refresh_many!)

    expect { described_class.perform_now([]) }.not_to have_enqueued_job(IndexTestIdentitiesJob)
    expect(TestInsights::TestIdentity).not_to have_received(:refresh_many!)
  end

  it "runs on the plugin queue, off the compute workers that run graders" do
    expect { described_class.perform_later([ 1 ]) }.to have_enqueued_job(described_class).on_queue("plugin_test_insights")
  end
end
