require "rails_helper"

# Plugin-declared metrics, and the enable/disable semantics they inherit.
RSpec.describe "Plugin metric declaration", :reset_plugin_registry do
  around do |example|
    installers = Syrus::Installer.snapshot
    registry = Syrus::Metrics.registry
    Syrus::PluginRegistry.reset!
    Syrus::Installer.clear_registrations!
    Syrus::Metrics.reset!
    example.run
  ensure
    Syrus::Installer.restore(installers)
    Syrus::Metrics.instance_variable_set(:@registry, registry)
    Syrus::PluginRegistry.restore(Syrus::PluginRegistry.boot_snapshot) if Syrus::PluginRegistry.boot_snapshot
  end

  # The registry applies the prefix, not the plugin author, so a plugin cannot
  # declare into core's namespace by accident or otherwise.
  it "namespaces a plugin's metrics under its own name" do
    Syrus::Metrics.declare_plugin("git_history") do
      counter :relay_requests_total, tags: %i[outcome], comment: "Reads served"
    end

    definition = Syrus::Metrics.definitions.sole
    expect(definition.name).to eq(:syrus_git_history_relay_requests_total)
    expect(definition.owner).to eq("git_history")
    expect(definition).not_to be_core
  end

  it "cannot reach core's namespace" do
    Syrus::Metrics.declare { counter :runs_total }

    # Same leaf name from a plugin lands somewhere else entirely rather than
    # shadowing core's series.
    Syrus::Metrics.declare_plugin("some_plugin") { counter :runs_total }

    expect(Syrus::Metrics.definitions.map(&:name))
      .to contain_exactly(:syrus_runs_total, :syrus_some_plugin_runs_total)
  end

  # A disabled plugin registers nothing, so its metrics are *absent* rather than
  # zero. That distinction is the whole point: zero means "shipped, nobody uses
  # it" and is actionable; absent means "not applicable".
  it "removes a plugin's metrics when it is undeclared" do
    names = Syrus::Metrics.declare_plugin("temp_plugin") { counter :thing_total }
    expect(Syrus::Metrics.registry.declared?(:syrus_temp_plugin_thing_total)).to be(true)

    Syrus::Metrics.undeclare(names)

    expect(Syrus::Metrics.registry.declared?(:syrus_temp_plugin_thing_total)).to be(false)
    expect(Syrus::Metrics.render).not_to include("syrus_temp_plugin_thing_total")
  end

  it "holds plugin metrics to the same cardinality rule as core" do
    expect {
      Syrus::Metrics.declare_plugin("bad_plugin") { counter :leaky_total, tags: %i[run_id] }
    }.to raise_error(Syrus::Metrics::Error, /identifies one Run/)
  end

  describe "the manifest DSL" do
    it "declares through while_enabled, so disabling tears the metrics down" do
      definition = Syrus::PluginApi::Definition.new(
        name: "probe_plugin", namespace: Module.new, lib_dir: Rails.root.to_s
      )
      definition.metrics do
        counter :probe_total, tags: %i[outcome], comment: "Probe"
      end

      effect = definition.effects.sole
      expect(effect[:scoped]).to be(true), "plugin metrics must be while_enabled, not always"

      # Installing the effect declares; disposing the returned teardown removes.
      scope = Syrus::EffectScope.new(label: "probe")
      effect[:block].call(scope)
      expect(Syrus::Metrics.registry.declared?(:syrus_probe_plugin_probe_total)).to be(true)

      scope.dispose
      expect(Syrus::Metrics.registry.declared?(:syrus_probe_plugin_probe_total)).to be(false)
    end

    it "retains metric metadata on the manifest for disabled-plugin admin detail pages" do
      definition = Syrus::PluginApi::Definition.new(
        name: "probe_plugin", namespace: Module.new, lib_dir: Rails.root.to_s
      )
      definition.metrics do
        counter :probe_total, tags: %i[outcome], comment: "Probe"
      end

      expect(definition.manifest_arguments.fetch(:metrics)).to contain_exactly(
        include(
          "name" => "syrus_probe_plugin_probe_total",
          "type" => "counter",
          "tags" => [ "outcome" ],
          "owner" => "probe_plugin",
          "comment" => "Probe"
        )
      )
    end
  end
end
