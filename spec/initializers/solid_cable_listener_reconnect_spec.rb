require "rails_helper"
require "action_cable/subscription_adapter/solid_cable"

# Regression: a MySQL restart longer than one immediate retry killed the
# Solid Cable listener thread for good, silently freezing every live update
# in the web process until it was restarted.
RSpec.describe SolidCableListenerReconnect do
  let(:listener_class) { ActionCable::SubscriptionAdapter::SolidCable::Listener }

  # Built without #initialize so no polling thread starts.
  let(:listener) do
    listener_class.allocate.tap { |listener| listener.instance_variable_set(:@reconnect_attempt, 0) }
  end

  it "is installed on the Solid Cable listener" do
    expect(listener_class.ancestors).to include(described_class)
  end

  it "keeps reconnecting far past the gem's single default attempt" do
    allow(listener).to receive(:sleep)

    results = Array.new(20) { listener.send(:retry_connecting?) }

    expect(results).to all(be(true))
    expect(listener).to have_received(:sleep).exactly(20).times
  end

  it "backs off to a capped delay" do
    expect((1..8).map { |attempt| described_class.delay_for(attempt) }).to eq([ 1, 2, 4, 8, 16, 30, 30, 30 ])
  end
end
