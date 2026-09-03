require "rails_helper"

RSpec.describe Throughput::UiSlots do
  let(:repository) { Factories.repository }

  it "contributes a panel to the repository detail slot" do
    panels = described_class.ui_slots(slot: "repository.detail", context: { repository: repository })

    expect(panels).to eq([ { id: "throughput.panel", component: "throughput/ThroughputPanel", order: 20 } ])
  end

  it "contributes nothing to other slots" do
    expect(described_class.ui_slots(slot: "job.detail", context: { repository: repository })).to eq([])
  end

  it "stays hidden in simple mode" do
    AppSetting.current.update!(mode: "simple", mode_configured_at: Time.current)

    expect(described_class.ui_slots(slot: "repository.detail", context: { repository: repository })).to eq([])
  end

  it "is registered on the repository detail slot through the payload" do
    panels = App::UiSlotsPayload.panels_for(slot: "repository.detail", context: { repository: repository, user: repository.user })

    expect(panels.map { |p| p[:id] }).to include("throughput.panel")
  end
end
