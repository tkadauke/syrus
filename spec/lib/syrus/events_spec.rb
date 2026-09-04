require "rails_helper"

RSpec.describe Syrus::Events do
  include ActiveJob::TestHelper

  def subscriber(subscriptions, &block)
    Class.new do
      include Syrus::Plugin::DomainSubscriber

      class_attribute :subs, :received
      self.subs = subscriptions
      self.received = []

      def self.subscriptions = subs

      def self.on_event(event)
        self.received += [ event ]
        raise "boom" if @raise_on_call
      end

      def self.raise_on_call! = @raise_on_call = true
    end.tap { |klass| block&.call(klass) }
  end

  def register(provider, name: "subscriber_plugin", home_queue: :default)
    Syrus::PluginRegistry.register(
      name: name, version: "1.0.0", home_queue: home_queue,
      provides: { domain_subscriber: provider }
    )
  end

  it "rejects an event name that is not declared" do
    expect { described_class.publish("nope.happened") }
      .to raise_error(described_class::UnknownEvent, /nope.happened/)
  end

  it "delivers an inline event synchronously" do
    klass = subscriber({ "step.grader.completed" => :on_event })
    register(klass)

    described_class.publish("step.grader.completed", run_id: 7, grader_name: "rspec")

    expect(klass.received.map(&:name)).to eq([ "step.grader.completed" ])
    expect(klass.received.first[:run_id]).to eq(7)
  end

  it "isolates the publisher from an inline subscriber that raises" do
    klass = subscriber({ "step.grader.completed" => :on_event })
    klass.raise_on_call!
    register(klass)

    expect { described_class.publish("step.grader.completed", run_id: 7) }.not_to raise_error
  end

  it "enqueues async events instead of running them inline" do
    klass = subscriber({ "job.closed" => :on_event })
    register(klass)

    expect { described_class.publish("job.closed", job_id: 3) }
      .to have_enqueued_job(DomainEventJob)
    expect(klass.received).to eq([])
  end

  it "does not deliver to a plugin that did not subscribe to the event" do
    klass = subscriber({ "job.approved" => :on_event })
    register(klass)

    expect { described_class.publish("job.closed", job_id: 3) }.not_to have_enqueued_job(DomainEventJob)
  end

  it "does not deliver to a disabled plugin" do
    klass = subscriber({ "step.grader.completed" => :on_event })
    register(klass)
    PluginRecord.find_or_create_by!(name: "subscriber_plugin").update!(enabled: false, disableable: true)

    described_class.publish("step.grader.completed", run_id: 7)

    expect(klass.received).to eq([])
  end

  it "does not deliver to a plugin whose hard dependency is missing" do
    klass = subscriber({ "step.grader.completed" => :on_event })
    Syrus::PluginRegistry.register(
      name: "degraded_plugin", version: "1.0.0", depends_on: [ "absent" ],
      provides: { domain_subscriber: klass }
    )

    described_class.publish("step.grader.completed", run_id: 7)

    expect(klass.received).to eq([])
  end

  it "routes an async event onto the subscribing plugin's home queue" do
    klass = subscriber({ "job.closed" => :on_event })
    register(klass, name: "queued_plugin", home_queue: :indexing)

    expect { described_class.publish("job.closed", job_id: 3) }
      .to have_enqueued_job(DomainEventJob).on_queue("indexing")
  end

  it "carries plain data, not Active Record objects" do
    klass = subscriber({ "step.grader.completed" => :on_event })
    register(klass)

    described_class.publish("step.grader.completed", run_id: 7, nested: { a: 1 })

    payload = klass.received.first.payload
    expect(payload).to eq({ run_id: 7, nested: { a: 1 } })
    expect(payload).to be_frozen
  end

  it "does not take down the publisher when a subscriber cannot be enqueued" do
    klass = subscriber({ "job.closed" => :on_event })
    register(klass)
    error = SolidQueue::Job::EnqueueError.new(
      ActiveRecord::StatementInvalid.new("Could not find table 'solid_queue_jobs'")
    )
    allow(DomainEventJob).to receive(:set).and_raise(error)
    expect(Rails.logger).to receive(:error).with(include("[Syrus::Events] could not enqueue job.closed"))

    expect { described_class.publish("job.closed", job_id: 3) }.not_to raise_error
  end
end
