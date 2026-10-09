require "rails_helper"

RSpec.describe "Stable plugin dependencies" do
  it "does not let stable bundled plugins hard-depend on experimental plugins" do
    Syrus::PluginRegistry.restore(Syrus::PluginRegistry.boot_snapshot)
    manifests = Syrus::PluginRegistry.all_plugins
    by_name = manifests.index_by(&:name)

    violations = manifests.reject(&:experimental?).flat_map do |manifest|
      Array(manifest.depends_on).filter_map do |dependency_name|
        dependency = by_name[dependency_name]
        "#{manifest.name} depends_on #{dependency_name}" if dependency&.experimental?
      end
    end

    expect(violations).to be_empty
  end
end
