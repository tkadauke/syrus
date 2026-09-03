require "rails_helper"

RSpec.describe DomainEventJob do
  def subscriber
    Class.new do
      include Syrus::Plugin::DomainSubscriber

      class_attribute :received
      self.received = []

      def self.subscriptions = { "job.closed" => :on_job_closed }
      def self.on_job_closed(event) = self.received += [ event ]
    end
  end

  it "delivers the event to the named subscriber" do
    klass = subscriber
    stub_const("DeliveredSubscriber", klass)
    Syrus::PluginRegistry.register(name: "delivery_plugin", version: "1.0.0", provides: { domain_subscriber: klass })

    described_class.perform_now("job.closed", { "job_id" => 5 }, "DeliveredSubscriber")

    expect(klass.received.map { |e| e[:job_id] }).to eq([ 5 ])
  end

  it "drops the event when the plugin was disabled between publish and delivery" do
    klass = subscriber
    stub_const("DisabledSubscriber", klass)
    Syrus::PluginRegistry.register(name: "delivery_plugin", version: "1.0.0", provides: { domain_subscriber: klass })
    PluginRecord.find_or_create_by!(name: "delivery_plugin").update!(enabled: false, disableable: true)

    expect { described_class.perform_now("job.closed", { "job_id" => 5 }, "DisabledSubscriber") }.not_to raise_error
    expect(klass.received).to eq([])
  end
end
