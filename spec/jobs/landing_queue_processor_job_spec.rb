require "rails_helper"

RSpec.describe LandingQueueProcessorJob do
  it "delegates to the processor" do
    allow(LandingQueueProcessor).to receive(:call)

    described_class.perform_now

    expect(LandingQueueProcessor).to have_received(:call)
  end

  it "is inert when polling is paused" do
    AppSetting.current.update!(polling_paused: true)
    allow(LandingQueueProcessor).to receive(:call)

    described_class.perform_now

    expect(LandingQueueProcessor).not_to have_received(:call)
  ensure
    AppSetting.current.update!(polling_paused: false)
  end
end
