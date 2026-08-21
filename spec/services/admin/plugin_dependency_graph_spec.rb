require "rails_helper"

RSpec.describe Admin::PluginDependencyGraph do
  around do |ex|
    Syrus::PluginRegistry.reset!
    ex.run
    Syrus::PluginRegistry.reset!
  end

  def register(name, depends_on: [])
    Syrus::PluginRegistry.register(name: name, version: "1.0.0", depends_on: depends_on)
  end

  describe "#dependencies_for" do
    it "returns an empty array for a plugin with no dependencies" do
      register("ruby")

      expect(described_class.new(Syrus::PluginRegistry.all_plugins).dependencies_for("ruby")).to eq([])
    end

    it "returns an empty array for an unknown plugin name" do
      expect(described_class.new(Syrus::PluginRegistry.all_plugins).dependencies_for("nonexistent")).to eq([])
    end

    it "returns direct dependencies" do
      register("ruby")
      register("rails", depends_on: [ "ruby" ])

      expect(described_class.new(Syrus::PluginRegistry.all_plugins).dependencies_for("rails")).to eq([ "ruby" ])
    end

    it "returns transitive dependencies" do
      register("python")
      register("django", depends_on: [ "python" ])

      graph = described_class.new(Syrus::PluginRegistry.all_plugins)
      expect(graph.dependencies_for("django")).to contain_exactly("python")
    end

    it "walks multiple levels of transitive dependencies" do
      register("a")
      register("b", depends_on: [ "a" ])
      register("c", depends_on: [ "b" ])

      graph = described_class.new(Syrus::PluginRegistry.all_plugins)
      expect(graph.dependencies_for("c")).to contain_exactly("a", "b")
    end

    it "does not loop forever on a dependency cycle" do
      register("a", depends_on: [ "b" ])
      register("b", depends_on: [ "a" ])

      graph = described_class.new(Syrus::PluginRegistry.all_plugins)
      expect { graph.dependencies_for("a") }.not_to raise_error
      expect(graph.dependencies_for("a")).to contain_exactly("a", "b")
    end
  end

  describe "#dependents_for" do
    it "returns an empty array when nothing depends on the plugin" do
      register("ruby")

      expect(described_class.new(Syrus::PluginRegistry.all_plugins).dependents_for("ruby")).to eq([])
    end

    it "returns plugins that directly declare a dependency on the plugin" do
      register("ruby")
      register("rails", depends_on: [ "ruby" ])

      expect(described_class.new(Syrus::PluginRegistry.all_plugins).dependents_for("ruby")).to contain_exactly("rails")
    end

    it "returns plugins that transitively depend on the plugin" do
      register("python")
      register("django", depends_on: [ "python" ])
      register("django_admin_extras", depends_on: [ "django" ])

      graph = described_class.new(Syrus::PluginRegistry.all_plugins)
      expect(graph.dependents_for("python")).to contain_exactly("django", "django_admin_extras")
    end

    it "does not loop forever on a dependency cycle" do
      register("a", depends_on: [ "b" ])
      register("b", depends_on: [ "a" ])

      graph = described_class.new(Syrus::PluginRegistry.all_plugins)
      expect { graph.dependents_for("a") }.not_to raise_error
    end
  end
end
