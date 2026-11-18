require "rails_helper"

RSpec.describe PluginDesiredStatePublishJob do
  it "publishes the current desired state on the control-plane queue" do
    allow(PluginDesiredState::Publisher).to receive(:publish!)

    described_class.perform_now

    expect(PluginDesiredState::Publisher).to have_received(:publish!)
    expect(described_class.queue_name).to eq("control_plane")
  end
end
