require "rails_helper"

RSpec.describe Admin::PluginDisableGuard do
  around do |ex|
    Syrus::PluginRegistry.reset!
    ex.run
    Syrus::PluginRegistry.reset!
  end

  def register(name, depends_on: [], provides: {})
    Syrus::PluginRegistry.register(name: name, version: "1.0.0", depends_on: depends_on, provides: provides)
  end

  def manifest_for(name)
    Syrus::PluginRegistry.all_plugins.find { |m| m.name == name }
  end

  describe ".blockers_for / .ensure_disableable!" do
    it "is unchanged for a plugin with no dependents and no usage" do
      register("solo_plugin")

      expect(described_class.blockers_for(manifest_for("solo_plugin"))).to eq([])
      expect { described_class.ensure_disableable!(manifest_for("solo_plugin")) }.not_to raise_error
    end

    it "still raises Blocked for usage blockers even when the plugin also has enabled dependents" do
      register("ruby", provides: { agent_provider: AdminPluginsSpec::AvailableProvider })
      register("rails", depends_on: [ "ruby" ])
      admin = Factories.user(admin: true)
      admin.update!(agent_provider: "available")

      expect { described_class.ensure_disableable!(manifest_for("ruby")) }
        .to raise_error(described_class::Blocked)
    end
  end

  describe ".dependents_for" do
    it "returns an empty array when no plugin depends on this one" do
      register("solo_plugin")

      expect(described_class.dependents_for(manifest_for("solo_plugin"))).to eq([])
    end

    it "returns currently-enabled plugins that transitively depend on this one" do
      register("ruby")
      register("rails", depends_on: [ "ruby" ])

      expect(described_class.dependents_for(manifest_for("ruby"))).to contain_exactly("rails")
    end

    it "excludes dependents that are already disabled" do
      register("ruby")
      register("rails", depends_on: [ "ruby" ])
      PluginRecord.find_by!(name: "rails").update!(enabled: false)

      expect(described_class.dependents_for(manifest_for("ruby"))).to eq([])
    end

    it "includes transitive dependents several levels deep" do
      register("python")
      register("django", depends_on: [ "python" ])
      register("django_extras", depends_on: [ "django" ])

      expect(described_class.dependents_for(manifest_for("python"))).to contain_exactly("django", "django_extras")
    end
  end
end
