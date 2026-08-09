require "rails_helper"

RSpec.describe PluginLifecycleJob, :reset_plugin_registry do
  around do |ex|
    Syrus::PluginRegistry.reset!
    ex.run
    Syrus::PluginRegistry.reset!
  end

  let(:callbacks_class) do
    Class.new do
      include Syrus::Plugin::Callbacks
      class << self
        attr_reader :last_event
        def on_enable = @last_event = :enable
        def on_disable = @last_event = :disable
      end
    end
  end

  before do
    Syrus::PluginRegistry.register(
      name: "lifecycle_plugin",
      version: "1.0.0",
      provides: { callbacks: callbacks_class }
    )
  end

  it "calls on_enable when event is on_enable" do
    described_class.perform_now("lifecycle_plugin", "on_enable")
    expect(callbacks_class.last_event).to eq(:enable)
  end

  it "calls on_disable when event is on_disable" do
    described_class.perform_now("lifecycle_plugin", "on_disable")
    expect(callbacks_class.last_event).to eq(:disable)
  end

  it "does nothing when the plugin has no callback provider" do
    Syrus::PluginRegistry.register(name: "no_callbacks_plugin", version: "1.0.0")

    expect { described_class.perform_now("no_callbacks_plugin", "on_enable") }.not_to raise_error
  end

  it "does nothing when the plugin is not registered" do
    expect { described_class.perform_now("unknown_plugin", "on_enable") }.not_to raise_error
  end

  it "enqueues on the control_plane queue" do
    expect {
      described_class.perform_later("lifecycle_plugin", "on_enable")
    }.to have_enqueued_job(described_class).on_queue("control_plane")
  end
end
