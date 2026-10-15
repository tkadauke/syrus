require "rails_helper"

RSpec.describe Admin::PluginEnabler, :reset_plugin_registry do
  it "enables the plugin and its transitive dependencies" do
    Syrus::PluginRegistry.register(name: "runtime", version: "1.0.0", default_enabled: false)
    Syrus::PluginRegistry.register(name: "language", version: "1.0.0", default_enabled: false, depends_on: [ "runtime" ])
    Syrus::PluginRegistry.register(name: "framework", version: "1.0.0", default_enabled: false, depends_on: [ "language" ])
    records = PluginRecord.where(name: %w[framework language runtime]).index_by(&:name)
    records.each_value { |record| record.update!(enabled: false) }

    described_class.enable!(records.fetch("framework"))

    expect(records.transform_values { |record| record.reload.enabled? }).to eq(
      "framework" => true,
      "language" => true,
      "runtime" => true
    )
  end

  it "does not partially enable a cascade containing an experimental dependency" do
    Syrus::PluginRegistry.register(name: "experimental-runtime", version: "1.0.0", experimental: true, default_enabled: false)
    Syrus::PluginRegistry.register(name: "framework", version: "1.0.0", default_enabled: false, depends_on: [ "experimental-runtime" ])
    framework = PluginRecord.find_by!(name: "framework")
    dependency = PluginRecord.find_by!(name: "experimental-runtime")

    expect { described_class.enable!(framework) }
      .to raise_error(described_class::ExperimentalPluginsBlocked)

    expect(framework.reload.enabled?).to be(false)
    expect(dependency.reload.enabled?).to be(false)
  end
end
