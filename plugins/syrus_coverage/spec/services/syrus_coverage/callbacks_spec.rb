require "rails_helper"

RSpec.describe SyrusCoverage::Callbacks do
  it "runs the hit map TTL sweep on the plugin's own tick instead of a host recurring entry" do
    expect { described_class.on_tick }.to have_enqueued_job(SyrusCoverage::HitMapTtlPruneJob)
    expect(Rails.root.join("config/recurring.yml").read).not_to include("HitMapTtlPruneJob")
  end
end
