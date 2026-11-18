require "rails_helper"

RSpec.describe PluginRouteHealth do
  after { Syrus::PluginInvocation.runtime_health = Syrus::PluginRuntimeHealth.new }

  it "records runtime health when the persistent health write fails" do
    health = Syrus::PluginRuntimeHealth.new
    Syrus::PluginInvocation.runtime_health = health
    allow(PluginRecord).to receive(:where).and_raise(ActiveRecord::ConnectionNotEstablished, "database unavailable")
    allow(Rails.logger).to receive(:warn)

    described_class.record_error("route_fixture", RuntimeError.new("route failed"))

    expect(health.failures(plugin: "route_fixture").sole).to have_attributes(
      extension_point: "route",
      operation: "dispatch",
      message: "route failed"
    )
    expect(Rails.logger).to have_received(:warn).with(
      "[PluginRouteHealth] failed to record health for route_fixture: " \
      "ActiveRecord::ConnectionNotEstablished: database unavailable"
    )
  end
end
