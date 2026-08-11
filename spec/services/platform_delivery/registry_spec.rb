require "rails_helper"

RSpec.describe PlatformDelivery::Registry do
  describe ".for" do
    it "returns a WebAdapter for the 'web' platform" do
      expect(described_class.for("web")).to be_a(PlatformDelivery::WebAdapter)
    end

    it "returns a BaseAdapter for unknown platforms" do
      expect(described_class.for("unknown_platform")).to be_a(PlatformDelivery::BaseAdapter)
    end

    it "returns a BaseAdapter for nil platform" do
      expect(described_class.for(nil)).to be_a(PlatformDelivery::BaseAdapter)
    end
  end

  describe ".registered?" do
    it "is true for built-in adapters" do
      expect(described_class.registered?("web")).to be true
    end

    it "is false for unknown platforms" do
      expect(described_class.registered?("unknown_platform")).to be false
    end
  end

  describe ".register" do
    let(:custom_adapter_class) do
      Class.new(PlatformDelivery::BaseAdapter) do
        def deliver(message:, platform_identity:) = "custom"
      end
    end

    after do
      # Reset runtime adapters after each example so tests don't bleed
      described_class.instance_variable_set(:@runtime_adapters, {})
    end

    it "registers an adapter for a platform and returns it via .for" do
      described_class.register("test_platform", custom_adapter_class)
      expect(described_class.for("test_platform")).to be_a(custom_adapter_class)
      expect(described_class.registered?("test_platform")).to be true
    end

    it "registered adapters take precedence over ADAPTERS defaults" do
      custom = Class.new(PlatformDelivery::BaseAdapter)
      described_class.register("web", custom)
      expect(described_class.for("web")).to be_a(custom)
    end
  end

  describe "plugin-registered platforms" do
    let(:discord_adapter_class) do
      Class.new(PlatformDelivery::BaseAdapter) do
        include Syrus::Plugin::PlatformDelivery
        def self.platform_key = "discord"
        def deliver(message:, platform_identity:) = "discord delivery"
      end
    end

    around do |ex|
      Syrus::PluginRegistry.reset!
      ex.run
      Syrus::PluginRegistry.reset!
    end

    it ".for resolves a plugin-registered adapter by platform key" do
      Syrus::PluginRegistry.register(
        name: "discord_plugin", version: "1.0.0",
        provides: { platform_delivery: discord_adapter_class }
      )

      expect(described_class.for("discord")).to be_a(discord_adapter_class)
    end

    it ".registered? is true for a plugin-registered platform key" do
      Syrus::PluginRegistry.register(
        name: "discord_plugin", version: "1.0.0",
        provides: { platform_delivery: discord_adapter_class }
      )

      expect(described_class.registered?("discord")).to be true
    end

    it "does not resolve a disabled plugin's platform" do
      Syrus::PluginRegistry.register(
        name: "discord_plugin", version: "1.0.0", default_enabled: false,
        provides: { platform_delivery: discord_adapter_class }
      )

      expect(described_class.registered?("discord")).to be false
      expect(described_class.for("discord")).to be_a(PlatformDelivery::BaseAdapter)
    end
  end

  describe ".start_connectors!" do
    let(:connector_job_class) do
      Class.new(PlatformPollingJob) do
        def self.name = "FakeDiscordConnectorJob"

        private

        def configured? = true
        def poll_once = nil
      end
    end

    let(:discord_adapter_class_with_connector) do
      job_class = connector_job_class
      Class.new(PlatformDelivery::BaseAdapter) do
        include Syrus::Plugin::PlatformDelivery
        define_singleton_method(:platform_key) { "discord" }
        define_singleton_method(:connector_job_class) { job_class }
        def deliver(message:, platform_identity:) = nil
      end
    end

    let(:discord_adapter_class_without_connector) do
      Class.new(PlatformDelivery::BaseAdapter) do
        include Syrus::Plugin::PlatformDelivery
        def self.platform_key = "discord"
        def deliver(message:, platform_identity:) = nil
      end
    end

    around do |ex|
      Syrus::PluginRegistry.reset!
      ex.run
      Syrus::PluginRegistry.reset!
      PlatformPollingJob.registry.delete(connector_job_class)
    end

    context "with SolidQueue tables available" do
      before { ensure_solid_queue_test_tables! }
      after  { clear_solid_queue_test_tables! }

      it "starts a connector job class for an enabled plugin" do
        Syrus::PluginRegistry.register(
          name: "discord_plugin", version: "1.0.0",
          provides: { platform_delivery: discord_adapter_class_with_connector }
        )

        expect { described_class.start_connectors! }.to have_enqueued_job(connector_job_class)
      end

      it "does not start a connector job class for a disabled plugin" do
        Syrus::PluginRegistry.register(
          name: "discord_plugin", version: "1.0.0", default_enabled: false,
          provides: { platform_delivery: discord_adapter_class_with_connector }
        )

        expect { described_class.start_connectors! }.not_to have_enqueued_job(connector_job_class)
      end

      it "tolerates a StatementInvalid from SolidQueue without raising" do
        Syrus::PluginRegistry.register(
          name: "discord_plugin", version: "1.0.0",
          provides: { platform_delivery: discord_adapter_class_with_connector }
        )
        allow(SolidQueue::Job).to receive(:where).and_raise(ActiveRecord::StatementInvalid)

        expect { described_class.start_connectors! }.not_to raise_error
      end
    end

    it "skips providers with no connector_job_class" do
      Syrus::PluginRegistry.register(
        name: "discord_plugin", version: "1.0.0",
        provides: { platform_delivery: discord_adapter_class_without_connector }
      )

      expect { described_class.start_connectors! }.not_to raise_error
    end
  end

  describe PlatformDelivery::WebAdapter do
    it "delivers without raising" do
      adapter = described_class.new
      session = ChatSession.create!(user: Factories.user)
      message = ChatMessage.new(chat_session: session, role: "assistant", content: { "text" => "Hi" })
      identity = Factories.platform_identity

      expect { adapter.deliver(message: message, platform_identity: identity) }.not_to raise_error
    end

    it "returns nil (no-op since ActionCable handles web delivery)" do
      adapter = described_class.new
      result = adapter.deliver(message: double("msg"), platform_identity: double("identity"))
      expect(result).to be_nil
    end
  end

  describe PlatformDelivery::BaseAdapter do
    it "raises NotImplementedError on deliver" do
      adapter = described_class.new
      expect {
        adapter.deliver(message: double("msg"), platform_identity: double("identity"))
      }.to raise_error(NotImplementedError)
    end
  end
end
