require "rails_helper"

RSpec.describe VideoWalkthroughs::Callbacks do
  describe ".on_tick" do
    it "enqueues the retention prune job" do
      expect { described_class.on_tick }.to have_enqueued_job(VideoWalkthroughs::PruneJob)
    end
  end
end
