require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe PluginRepositoryConfiguration do
  class SyntheticRepositoryConfiguration
    include Syrus::Plugin::RepositoryConfiguration

    def self.key = "synthetic.rules"
    def self.schema_version = 2

    def self.parse(value:, version:, scope:)
      raise ArgumentError, "expected schema version 2" unless version == 2
      raise ArgumentError, "config must be a mapping" unless value.is_a?(Hash)

      value.deep_stringify_keys.merge("scope" => scope)
    end

    def self.serialize(value:)
      value.except("private_note")
    end

    def self.overlay(root:, project:)
      root.deep_merge(project)
    end

    def self.affected_project?(configuration:, project:, changed_files:)
      changed_files.any? { |path| path.start_with?(project.path.presence || "src/") }
    end
  end

  around do |example|
    snapshot = Syrus::PluginRegistry.snapshot
    example.run
  ensure
    Syrus::PluginRegistry.restore(snapshot)
  end

  it "parses, safely serializes, and selects affected projects through a versioned provider" do
    Syrus::PluginRegistry.register(:repository_configuration, SyntheticRepositoryConfiguration)

    config = SyrusYml.new(<<~YAML).parse
      plugins:
        synthetic.rules:
          version: 2
          config:
            nested:
              enabled: true
            private_note: do-not-expose
    YAML

    expect(config.plugin_configurations["synthetic.rules"]).to include(
      "nested" => { "enabled" => true }, "private_note" => "do-not-expose", "scope" => "root"
    )
    expect(config.plugin_configurations.to_h.dig("synthetic.rules", "config")).not_to have_key("private_note")

    project = TargetGraph::Project.new(id: "api", path: "api", plugin_configurations: config.plugin_configurations)
    expect(config.plugin_configurations.affected?("synthetic.rules", project:, changed_files: [ "api/model.rb" ])).to be(true)
    expect(config.plugin_configurations.affected?("synthetic.rules", project:, changed_files: [ "web/page.tsx" ])).to be(false)
  end

  it "overlays root and nested project values and keeps deterministic key ordering" do
    second = Class.new(SyntheticRepositoryConfiguration) do
      def self.key = "synthetic.alpha"
    end
    Syrus::PluginRegistry.register(:repository_configuration, SyntheticRepositoryConfiguration)
    Syrus::PluginRegistry.register(:repository_configuration, second)

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".syrus.yml"), <<~YAML)
        plugins:
          synthetic.rules:
            version: 2
            config: { nested: { root: true } }
          synthetic.alpha:
            version: 2
            config: { root: true }
      YAML
      FileUtils.mkdir_p(File.join(dir, "api"))
      File.write(File.join(dir, "api", ".syrus.yml"), <<~YAML)
        plugins:
          synthetic.rules:
            version: 2
            config: { nested: { project: true } }
      YAML

      graph = TargetGraph::Compiler.compile(dir)
      project = graph.project("api")
      expect(project.plugin_configurations.keys).to eq(%w[synthetic.alpha synthetic.rules])
      expect(project.plugin_configurations["synthetic.rules"].fetch("nested")).to eq(
        "root" => true, "project" => true
      )
      expect(graph.affected_projects_for_configuration("synthetic.rules", changed_files: [ "api/model.rb" ]).map(&:id)).to eq([ "api" ])
    end
  end

  it "reports absent and disabled providers without materializing their configuration" do
    Syrus::PluginRegistry.register(
      name: "synthetic", version: "1", provides: { repository_configuration: SyntheticRepositoryConfiguration }
    )
    PluginRecord.find_by!(name: "synthetic").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    config = SyrusYml.new(<<~YAML).parse
      plugins:
        synthetic.rules: { version: 2, config: {} }
        removed.rules: { version: 1, config: {} }
    YAML

    expect(config.plugin_configurations).to be_empty
    expect(config.plugin_configurations.diagnostics.map(&:to_h)).to include(
      include("key" => "synthetic.rules", "owner" => "synthetic", "status" => "disabled"),
      include("key" => "removed.rules", "owner" => "removed", "status" => "absent")
    )
  end

  it "rejects invalid envelopes and provider schemas" do
    Syrus::PluginRegistry.register(:repository_configuration, SyntheticRepositoryConfiguration)

    expect { SyrusYml.new("plugins: []").parse }.to raise_error(SyrusYml::ParseError, /plugins: must be a mapping/)
    expect do
      SyrusYml.new("plugins:\n  synthetic.rules: { version: 1, config: {} }").parse
    end.to raise_error(SyrusYml::ParseError, /expected schema version 2/)
    expect do
      SyrusYml.new("plugins:\n  synthetic.rules: { version: 2, config: [] }").parse
    end.to raise_error(SyrusYml::ParseError, /config must be a mapping/)
  end

  it "uses the replacement provider after a registry reload" do
    Syrus::PluginRegistry.register(:repository_configuration, SyntheticRepositoryConfiguration)
    first = SyrusYml.new("plugins:\n  synthetic.rules: { version: 2, config: {} }").parse
    expect(first.plugin_configurations["synthetic.rules"]).to include("scope" => "root")

    replacement = Class.new(SyntheticRepositoryConfiguration) do
      def self.parse(value:, version:, scope:) = { "reloaded" => true }
    end
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(:repository_configuration, replacement)

    reloaded = SyrusYml.new("plugins:\n  synthetic.rules: { version: 2, config: {} }").parse
    expect(reloaded.plugin_configurations["synthetic.rules"]).to eq("reloaded" => true)
  end

  it "keeps the legacy coworker review path working through its compatibility adapter" do
    record = PluginRecord.find_by!(name: "coworkers")
    record.update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    config = SyrusYml.new("coworker_review:\n  enabled: true\n  rounds: 2\n  criteria: [be exact]\n").parse

    expect(config.coworker_review.rounds).to eq(2)
    expect(config.plugin_configurations["coworkers.review"]).to eq(config.coworker_review)
    expect(config.plugin_configurations.to_h.dig("coworkers.review", "config", "criteria")).to eq([ "be exact" ])
  end
end
