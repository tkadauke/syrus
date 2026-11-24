require "rails_helper"

RSpec.describe Achievements::Subscribers do
  let(:event) do
    Syrus::DomainEvent.new(name: "epic.upserted", payload: { epic_id: 7, user_id: 1, state: "done", origin: "operator" })
  end

  it "subscribes only to events the evaluators understand, all of which core declares" do
    expect(described_class.subscriptions.keys).to contain_exactly("job.closed", "epic.upserted")
    expect(described_class.subscriptions.keys).to all(satisfy { |name| Syrus::Events.known?(name) })
  end

  it "evaluates events while enabled" do
    allow(Achievements).to receive(:enabled?).and_return(true)

    expect { described_class.on_event(event) }.to change(Achievements::Unlock, :count).by(1)
  end

  it "does nothing once the plugin is disabled" do
    allow(Achievements).to receive(:enabled?).and_return(false)

    expect { described_class.on_event(event) }.not_to change(Achievements::Unlock, :count)
  end

  it "is registered with core's event delivery only while the plugin is enabled" do
    PluginRecord.find_or_create_by!(name: "achievements").update!(enabled: true, disableable: true)
    expect(Syrus::Events.subscribers_for("job.closed").map { |provider, _| provider.to_s }).to include("Achievements::Subscribers")

    PluginRecord.find_by!(name: "achievements").update!(enabled: false)
    expect(Syrus::Events.subscribers_for("job.closed").map { |provider, _| provider.to_s }).not_to include("Achievements::Subscribers")
  end

  it "receives epic.upserted payload with the state and origin it needs from core" do
    epic = Factories.epic
    allow(Syrus::Events).to receive(:publish)

    epic.send(:publish_epic_upserted_event)

    expect(Syrus::Events).to have_received(:publish).with("epic.upserted", hash_including(epic_id: epic.id, state: epic.state, origin: epic.origin))
  end
end
