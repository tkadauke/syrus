require "rails_helper"

RSpec.describe "Calendar plugin" do
  it "hosts its event-source contract and registers built-in providers" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "calendar" }
    expect(manifest.hosted_extension_points).to include("calendar:event_source")
    expect(Syrus::PluginRegistry.providers_for("calendar:event_source"))
      .to include(Calendar::Sources::ChatWakeups, Calendar::Sources::RecurringMaintenance)
  end
end
