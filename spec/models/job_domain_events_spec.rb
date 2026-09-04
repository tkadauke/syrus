require "rails_helper"

RSpec.describe "Job domain events" do
  include ActiveJob::TestHelper

  def subscriber(event_name)
    Class.new do
      include Syrus::Plugin::DomainSubscriber

      class_attribute :event_name_to_watch, :received
      self.received = []
      self.event_name_to_watch = event_name

      def self.subscriptions = { event_name_to_watch => :on_event }
      def self.on_event(event) = self.received += [ event ]
    end
  end

  def register(klass)
    Syrus::PluginRegistry.register(name: "job_event_plugin", version: "1.0.0", provides: { domain_subscriber: klass })
  end

  it "publishes job.created when a Job is created" do
    klass = subscriber("job.created")
    register(klass)

    # Scoped to this subscriber: other plugins legitimately subscribe to Job
    # events too, and a bare count would break whenever one is added.
    expect { Factories.job }
      .to have_enqueued_job(DomainEventJob).with("job.created", anything, klass.to_s)
  end

  it "publishes job.closed with the closure reason" do
    klass = subscriber("job.closed")
    register(klass)
    job = Factories.job

    perform_enqueued_jobs do
      job.close_with_reason!("pr_merged")
    end

    closed = klass.received.select { |e| e.name == "job.closed" }
    expect(closed.size).to eq(1)
    expect(closed.first[:closure_reason]).to eq("pr_merged")
    expect(closed.first[:job_id]).to eq(job.id)
  end

  it "publishes job.state_changed with both states" do
    klass = subscriber("job.state_changed")
    register(klass)
    job = Factories.job

    perform_enqueued_jobs do
      job.close_with_reason!("pr_merged")
    end

    change = klass.received.find { |e| e.name == "job.state_changed" }
    expect(change[:state]).to eq("closed")
    expect(change[:previous_state]).not_to eq("closed")
  end

  it "does not deliver an event to a plugin that did not subscribe to it" do
    klass = subscriber("job.created")
    register(klass)
    job = Factories.job

    expect { job.close_with_reason!("pr_merged") }
      .not_to have_enqueued_job(DomainEventJob).with(anything, anything, klass.to_s)
  end
end
