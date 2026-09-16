require "rails_helper"

RSpec.describe TestInsights::Callbacks do
  include ActiveJob::TestHelper

  describe ".on_tick" do
    it "enqueues TestInsightsPruneJob" do
      expect { described_class.on_tick }.to have_enqueued_job(TestInsightsPruneJob)
    end
  end
end
