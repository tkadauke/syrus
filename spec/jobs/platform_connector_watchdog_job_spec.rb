require "rails_helper"

RSpec.describe PlatformConnectorWatchdogJob do
  let(:connector_job_class) do
    Class.new(PlatformPollingJob) do
      cattr_accessor :configured_flag
      self.configured_flag = true

      def self.name = "FakeDiscordConnectorJob"

      private

      def configured? = self.class.configured_flag
      def poll_once = nil
    end
  end

  let(:discord_adapter_class) do
    job_class = connector_job_class
    Class.new(PlatformDelivery::BaseAdapter) do
      include Syrus::Plugin::PlatformDelivery
      define_singleton_method(:platform_key) { "discord" }
      define_singleton_method(:connector_job_class) { job_class }
      def deliver(message:, platform_identity:) = nil
    end
  end

  around do |ex|
    Syrus::PluginRegistry.reset!
    ex.run
    Syrus::PluginRegistry.reset!
    PlatformPollingJob.registry.delete(connector_job_class)
  end

  before { ensure_solid_queue_test_tables! }
  after  { clear_solid_queue_test_tables! }

  describe "#perform" do
    it "re-enqueues a missing configured plugin connector and logs a recovery warning" do
      Syrus::PluginRegistry.register(
        name: "discord_plugin", version: "1.0.0",
        provides: { platform_delivery: discord_adapter_class }
      )

      expect(Rails.logger).to receive(:warn).with(include("FakeDiscordConnectorJob").and(include("re-enqueued")))

      expect { described_class.perform_now }.to have_enqueued_job(connector_job_class)
    end

    it "skips a connector that already has an unfinished job (no duplicate session, no log)" do
      Syrus::PluginRegistry.register(
        name: "discord_plugin", version: "1.0.0",
        provides: { platform_delivery: discord_adapter_class }
      )
      SolidQueue::Job.create!(
        class_name: connector_job_class.name,
        queue_name: "polling",
        priority: 0,
        arguments: "{}"
      )

      expect(Rails.logger).not_to receive(:warn)

      expect { described_class.perform_now }.not_to have_enqueued_job(connector_job_class)
    end

    it "does not enqueue and does not log when the plugin is disabled" do
      Syrus::PluginRegistry.register(
        name: "discord_plugin", version: "1.0.0", default_enabled: false,
        provides: { platform_delivery: discord_adapter_class }
      )

      expect(Rails.logger).not_to receive(:warn)

      expect { described_class.perform_now }.not_to have_enqueued_job(connector_job_class)
    end

    it "does not enqueue and does not log when the connector reports itself unconfigured" do
      Syrus::PluginRegistry.register(
        name: "discord_plugin", version: "1.0.0",
        provides: { platform_delivery: discord_adapter_class }
      )
      connector_job_class.configured_flag = false

      expect(Rails.logger).not_to receive(:warn)

      expect { described_class.perform_now }.not_to have_enqueued_job(connector_job_class)
    end

    it "also re-primes core (non-plugin) PlatformPollingJob subclasses" do
      core_class = Class.new(PlatformPollingJob) do
        def self.name = "FakeCorePollingJob"

        private

        def configured? = true
        def poll_once = nil
      end

      expect(Rails.logger).to receive(:warn).with(include("FakeCorePollingJob"))

      expect { described_class.perform_now }.to have_enqueued_job(core_class)

      PlatformPollingJob.registry.delete(core_class)
    end

    it "tolerates an unexpected error from a start call without raising" do
      allow(PlatformPollingJob).to receive(:start_all_with_status!).and_raise(RuntimeError, "boom")

      expect(Rails.logger).to receive(:warn).with(include("tick failed"))

      expect { described_class.perform_now }.not_to raise_error
    end
  end
end
