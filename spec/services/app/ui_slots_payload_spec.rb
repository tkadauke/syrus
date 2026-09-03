require "rails_helper"

RSpec.describe App::UiSlotsPayload do
  let(:repository) { Factories.repository }
  let(:user) { repository.user }

  def provider(panels)
    Class.new do
      include Syrus::Plugin::UiSlot

      class_attribute :panels_to_return, :calls
      self.panels_to_return = panels
      self.calls = []

      def self.ui_slots(slot:, context:)
        self.calls += [ { slot: slot, context: context } ]
        panels_to_return.fetch(slot, [])
      end
    end
  end

  def register(provider_class, name: "slot_plugin")
    Syrus::PluginRegistry.register(name: name, version: "1.0.0", provides: { ui_slot: provider_class })
  end

  it "returns nothing when no plugin contributes to the slot" do
    expect(described_class.panels_for(slot: "repository.detail")).to eq([])
  end

  it "returns panels contributed for the requested slot only" do
    register(provider({
      "repository.detail" => [ { id: "throughput", component: "throughput/Panel", order: 10 } ],
      "job.detail" => [ { id: "cache", component: "build_cache/Card", order: 10 } ]
    }))

    panels = described_class.panels_for(slot: "repository.detail")

    expect(panels).to eq([ { id: "throughput", component: "throughput/Panel", order: 10 } ])
  end

  it "passes the host page's context through to the provider" do
    klass = provider({ "repository.detail" => [] })
    register(klass)

    described_class.panels_for(slot: "repository.detail", context: { repository: repository, user: user })

    expect(klass.calls.last[:context]).to eq({ repository: repository, user: user })
  end

  it "orders panels by declared order, then registration order" do
    register(provider({ "repository.detail" => [ { id: "b", component: "x/B", order: 20 } ] }), name: "plugin_b")
    register(provider({ "repository.detail" => [ { id: "a", component: "x/A", order: 5 } ] }), name: "plugin_a")

    expect(described_class.panels_for(slot: "repository.detail").map { |p| p[:id] }).to eq(%w[a b])
  end

  it "omits panels from a disabled plugin" do
    klass = provider({ "repository.detail" => [ { id: "throughput", component: "throughput/Panel" } ] })
    register(klass)
    PluginRecord.find_or_create_by!(name: "slot_plugin").update!(enabled: false, disableable: true)

    expect(described_class.panels_for(slot: "repository.detail")).to eq([])
  end

  it "rejects an unknown slot name rather than silently rendering nothing" do
    expect { described_class.panels_for(slot: "nope.detail") }
      .to raise_error(ArgumentError, /Unknown UI slot/)
  end
end
