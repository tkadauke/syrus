require "rails_helper"

RSpec.describe TestInsights::Callbacks do
  include ActiveJob::TestHelper

  describe ".on_tick" do
    it "enqueues TestInsights::PruneJob" do
      expect { described_class.on_tick }.to have_enqueued_job(TestInsights::PruneJob)
    end
  end
end
