require "rails_helper"

RSpec.describe PluginLifecycleJob, :reset_plugin_registry do
  around do |ex|
    Syrus::PluginRegistry.reset!
    Syrus::Plugin::EffectRegistry.reset!
    ex.run
    Syrus::PluginRegistry.reset!
    Syrus::Plugin::EffectRegistry.reset!
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

  describe "effect draining" do
    let(:effectful_callbacks_class) do
      Class.new do
        include Syrus::Plugin::Callbacks
        class << self
          attr_accessor :enable_should_raise

          def on_boot
            effect { on_boot_cleanup_ran! }
          end

          def on_enable
            effect { on_enable_cleanup_ran! }
            raise "enable failed" if enable_should_raise
          end

          def on_disable
            effect { on_disable_cleanup_ran! }
          end

          def on_shutdown
            effect { on_shutdown_cleanup_ran! }
          end

          def on_boot_cleanup_ran? = @on_boot_cleanup_ran
          def on_boot_cleanup_ran! = @on_boot_cleanup_ran = true
          def on_enable_cleanup_ran? = @on_enable_cleanup_ran
          def on_enable_cleanup_ran! = @on_enable_cleanup_ran = true
          def on_disable_cleanup_ran? = @on_disable_cleanup_ran
          def on_disable_cleanup_ran! = @on_disable_cleanup_ran = true
          def on_shutdown_cleanup_ran? = @on_shutdown_cleanup_ran
          def on_shutdown_cleanup_ran! = @on_shutdown_cleanup_ran = true
        end
      end
    end

    before do
      Syrus::PluginRegistry.register(
        name: "effectful_plugin",
        version: "1.0.0",
        provides: { callbacks: effectful_callbacks_class }
      )
    end

    it "drains registered effects after on_disable" do
      described_class.perform_now("effectful_plugin", "on_disable")

      expect(effectful_callbacks_class.on_disable_cleanup_ran?).to be(true)
    end

    it "drains registered effects after on_shutdown" do
      described_class.perform_now("effectful_plugin", "on_shutdown")

      expect(effectful_callbacks_class.on_shutdown_cleanup_ran?).to be(true)
    end

    it "leaves no effects registered for a later drain once on_disable already drained them" do
      described_class.perform_now("effectful_plugin", "on_disable")

      expect { Syrus::Plugin::EffectRegistry.drain!("effectful_plugin") }.not_to raise_error
      expect(effectful_callbacks_class.on_disable_cleanup_ran?).to be(true)
    end

    it "drains effects registered during a failing on_enable, then re-raises" do
      effectful_callbacks_class.enable_should_raise = true

      expect {
        described_class.perform_now("effectful_plugin", "on_enable")
      }.to raise_error("enable failed")

      expect(effectful_callbacks_class.on_enable_cleanup_ran?).to be(true)
    end

    it "does not drain effects after a successful on_enable" do
      effectful_callbacks_class.enable_should_raise = false

      described_class.perform_now("effectful_plugin", "on_enable")

      expect(effectful_callbacks_class.on_enable_cleanup_ran?).to be_falsey

      Syrus::Plugin::EffectRegistry.drain!("effectful_plugin")

      expect(effectful_callbacks_class.on_enable_cleanup_ran?).to be(true)
    end

    it "drains effects registered during a failing on_boot, then re-raises" do
      raising_boot_class = Class.new do
        include Syrus::Plugin::Callbacks
        class << self
          def on_boot
            effect { on_boot_cleanup_ran! }
            raise "boot failed"
          end

          def on_boot_cleanup_ran? = @on_boot_cleanup_ran
          def on_boot_cleanup_ran! = @on_boot_cleanup_ran = true
        end
      end

      Syrus::PluginRegistry.register(
        name: "raising_boot_plugin",
        version: "1.0.0",
        provides: { callbacks: raising_boot_class }
      )

      expect {
        described_class.perform_now("raising_boot_plugin", "on_boot")
      }.to raise_error("boot failed")

      expect(raising_boot_class.on_boot_cleanup_ran?).to be(true)
    end
  end
end
