require "rails_helper"

RSpec.describe PluginTickSchedulerJob do
  include ActiveJob::TestHelper

  def callbacks_provider
    Class.new do
      include Syrus::Plugin::Callbacks

      class_attribute :ticks
      self.ticks = 0

      def self.on_tick = self.ticks += 1
    end
  end

  def register(name: "ticking_plugin", tick_interval: 30.seconds, home_queue: :default, depends_on: [])
    Syrus::PluginRegistry.register(
      name: name, version: "1.0.0", tick_interval: tick_interval,
      home_queue: home_queue, depends_on: depends_on,
      provides: { callbacks: callbacks_provider }
    )
  end

  it "enqueues a tick for a plugin that has never ticked" do
    register

    expect { described_class.perform_now }.to have_enqueued_job(PluginTickJob).with("ticking_plugin")
  end

  it "records when the tick was claimed" do
    register

    described_class.perform_now

    expect(PluginRecord.find_by(name: "ticking_plugin").last_ticked_at).to be_present
  end

  it "does not tick again before the interval has elapsed" do
    register(tick_interval: 1.hour)
    described_class.perform_now

    expect { described_class.perform_now }.not_to have_enqueued_job(PluginTickJob)
  end

  it "ticks again once the interval has elapsed" do
    register(tick_interval: 30.seconds)
    described_class.perform_now
    PluginRecord.find_by(name: "ticking_plugin").update!(last_ticked_at: 2.minutes.ago)

    expect { described_class.perform_now }.to have_enqueued_job(PluginTickJob)
  end

  it "skips a plugin with no tick_interval" do
    register(tick_interval: nil)

    expect { described_class.perform_now }.not_to have_enqueued_job(PluginTickJob)
  end

  it "skips a disabled plugin" do
    register
    PluginRecord.find_or_create_by!(name: "ticking_plugin").update!(enabled: false, disableable: true)

    expect { described_class.perform_now }.not_to have_enqueued_job(PluginTickJob)
  end

  it "skips a plugin whose hard dependency is missing" do
    register(depends_on: [ "absent" ])

    expect { described_class.perform_now }.not_to have_enqueued_job(PluginTickJob)
  end

  it "runs the tick on the plugin's home queue" do
    register(name: "connectivity_plugin", home_queue: :connectivity)

    expect { described_class.perform_now }
      .to have_enqueued_job(PluginTickJob).on_queue("connectivity")
  end

  it "fires the plugin's on_tick callback when the tick job runs" do
    register
    provider = Syrus::PluginRegistry.providers_for(:callbacks).last

    perform_enqueued_jobs { described_class.perform_now }

    expect(provider.ticks).to eq(1)
  end
end
