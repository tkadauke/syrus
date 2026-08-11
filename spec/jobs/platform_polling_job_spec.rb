require "rails_helper"

RSpec.describe PlatformPollingJob do
  # stub_const gives the class a real name so SolidQueue::Job.class_name
  # can store it. The constant is torn down after each example automatically.
  let(:concrete_class) { PlatformPollingTestSubclass }

  before do
    stub_const("PlatformPollingTestSubclass", Class.new(described_class) do
      cattr_accessor :configured_flag, :poll_calls_collector

      self.configured_flag = true
      self.poll_calls_collector = []

      private

      def configured? = self.class.configured_flag
      def poll_once   = self.class.poll_calls_collector << :poll
    end)
  end

  after do
    described_class.registry.delete(concrete_class)
  end

  describe "subclass registration" do
    it "adds the subclass to PlatformPollingJob.registry via inherited hook" do
      expect(described_class.registry).to include(concrete_class)
    end
  end

  describe "#perform" do
    it "calls poll_once when configured and not a duplicate" do
      allow_any_instance_of(concrete_class).to receive(:duplicate_running?).and_return(false)
      allow(concrete_class).to receive(:perform_later)

      concrete_class.new.perform

      expect(concrete_class.poll_calls_collector).to eq([:poll])
    end

    it "skips poll_once when not configured" do
      concrete_class.configured_flag = false
      allow(concrete_class).to receive(:perform_later)

      concrete_class.new.perform

      expect(concrete_class.poll_calls_collector).to be_empty
    end

    it "skips poll_once when duplicate_running? is true" do
      allow_any_instance_of(concrete_class).to receive(:duplicate_running?).and_return(true)
      allow(concrete_class).to receive(:perform_later)

      concrete_class.new.perform

      expect(concrete_class.poll_calls_collector).to be_empty
    end

    it "re-enqueues itself in ensure when configured" do
      allow_any_instance_of(concrete_class).to receive(:duplicate_running?).and_return(false)

      expect { concrete_class.new.perform }.to have_enqueued_job(concrete_class)
    end

    it "does not re-enqueue in ensure when not configured" do
      concrete_class.configured_flag = false

      expect { concrete_class.new.perform }.not_to have_enqueued_job(concrete_class)
    end

    it "logs errors from poll_once but still re-enqueues" do
      allow_any_instance_of(concrete_class).to receive(:duplicate_running?).and_return(false)
      allow_any_instance_of(concrete_class).to receive(:poll_once).and_raise(RuntimeError, "oops")

      expect(Rails.logger).to receive(:error).with(include("oops"))
      expect { concrete_class.new.perform }.to have_enqueued_job(concrete_class)
    end
  end

  describe "#duplicate_running?" do
    context "with SolidQueue tables available" do
      before { ensure_solid_queue_test_tables! }
      after  { clear_solid_queue_test_tables! }

      it "returns false when only one unfinished job exists" do
        SolidQueue::Job.create!(
          class_name: concrete_class.name,
          queue_name: "default",
          priority: 0,
          arguments: "{}"
        )
        instance = concrete_class.new
        expect(instance.send(:duplicate_running?)).to be false
      end

      it "returns true when more than one unfinished job exists" do
        2.times do
          SolidQueue::Job.create!(
            class_name: concrete_class.name,
            queue_name: "default",
            priority: 0,
            arguments: "{}"
          )
        end
        instance = concrete_class.new
        expect(instance.send(:duplicate_running?)).to be true
      end

      it "ignores finished jobs in the count" do
        SolidQueue::Job.create!(
          class_name: concrete_class.name,
          queue_name: "default",
          priority: 0,
          arguments: "{}",
          finished_at: 1.minute.ago
        )
        SolidQueue::Job.create!(
          class_name: concrete_class.name,
          queue_name: "default",
          priority: 0,
          arguments: "{}"
        )
        instance = concrete_class.new
        expect(instance.send(:duplicate_running?)).to be false
      end
    end

    context "when SolidQueue tables are unavailable" do
      it "returns false rather than raising" do
        allow(SolidQueue::Job).to receive(:where).and_raise(ActiveRecord::StatementInvalid)
        instance = concrete_class.new
        expect(instance.send(:duplicate_running?)).to be false
      end
    end
  end

  describe ".start_all!" do
    context "with SolidQueue tables available" do
      before { ensure_solid_queue_test_tables! }
      after  { clear_solid_queue_test_tables! }

      it "enqueues each registered subclass that is not already running" do
        expect { described_class.start_all! }.to have_enqueued_job(concrete_class)
      end

      it "skips a subclass that already has an unfinished SolidQueue job" do
        SolidQueue::Job.create!(
          class_name: concrete_class.name,
          queue_name: "default",
          priority: 0,
          arguments: "{}"
        )
        expect { described_class.start_all! }.not_to have_enqueued_job(concrete_class)
      end

      it "skips unconfigured subclasses" do
        concrete_class.configured_flag = false

        expect(described_class.start_all!).to eq([])
        expect { described_class.start_all! }.not_to have_enqueued_job(concrete_class)
      end
    end

    it "tolerates missing SolidQueue tables without raising" do
      allow(SolidQueue::Job).to receive(:where).and_raise(ActiveRecord::StatementInvalid)
      expect { described_class.start_all! }.not_to raise_error
    end

    context "when a subclass is a plugin's platform_delivery connector_job_class" do
      let(:plugin_adapter_class) do
        job_class = concrete_class
        Class.new do
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
      end

      before { ensure_solid_queue_test_tables! }
      after  { clear_solid_queue_test_tables! }

      it "excludes it so PlatformDelivery::Registry.start_connectors! is the one that starts it" do
        Syrus::PluginRegistry.register(
          name: "discord_plugin", version: "1.0.0",
          provides: { platform_delivery: plugin_adapter_class }
        )

        expect { described_class.start_all! }.not_to have_enqueued_job(concrete_class)
      end

      it "still starts it once the plugin is unregistered again" do
        expect { described_class.start_all! }.to have_enqueued_job(concrete_class)
      end
    end
  end
end
