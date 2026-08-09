require "rails_helper"

RSpec.describe PluginTickJob, :reset_plugin_registry do
  around do |ex|
    Syrus::PluginRegistry.reset!
    ex.run
    Syrus::PluginRegistry.reset!
  end

  let(:callbacks_class) do
    Class.new do
      include Syrus::Plugin::Callbacks
      class << self
        attr_reader :ticked
        def on_tick = @ticked = true
      end
    end
  end

  before do
    Syrus::PluginRegistry.register(
      name: "tick_plugin",
      version: "1.0.0",
      tick_interval: 5.minutes,
      provides: { callbacks: callbacks_class }
    )
  end

  it "calls on_tick on the plugin's callback provider" do
    described_class.perform_now("tick_plugin")
    expect(callbacks_class.ticked).to be(true)
  end

  it "does nothing when the plugin has no callback provider" do
    Syrus::PluginRegistry.register(name: "no_callbacks_plugin", version: "1.0.0")

    expect { described_class.perform_now("no_callbacks_plugin") }.not_to raise_error
  end

  it "does nothing when the plugin is not registered" do
    expect { described_class.perform_now("unknown_plugin") }.not_to raise_error
  end

  it "enqueues on the control_plane queue" do
    expect {
      described_class.perform_later("tick_plugin")
    }.to have_enqueued_job(described_class).on_queue("control_plane")
  end
end
