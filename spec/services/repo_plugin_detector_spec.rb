require "rails_helper"
require "tmpdir"

RSpec.describe RepoPluginDetector do
  around do |ex|
    Dir.mktmpdir("syrus-repo-plugin-detector") { |dir| @dir = dir; ex.run }
  end

  def write(rel, contents = "")
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  # Register the real bundled `ruby`, `javascript`, and `syrus-rails` plugins
  # (mirroring their engine.rb manifests), same approach as
  # repo_prep_plan_spec.rb — exercises production wiring rather than a
  # RepoPluginDetector-local fixture.
  before do
    unless Syrus::PluginRegistry.registered_names.include?("ruby")
      Syrus::PluginRegistry.register(
        name: "ruby", version: Ruby::VERSION, prepare_priority: 10,
        provides: { prepare_detector: Ruby::PrepareDetector }
      )
    end

    unless Syrus::PluginRegistry.registered_names.include?("javascript")
      Syrus::PluginRegistry.register(
        name: "javascript", version: JavaScript::VERSION, prepare_priority: 20,
        provides: { prepare_detector: JavaScript::PrepareDetector }
      )
    end

    unless Syrus::PluginRegistry.registered_names.include?("syrus-rails")
      Syrus::PluginRegistry.register(
        name: "syrus-rails", version: SyrusRails::VERSION, depends_on: [ "ruby" ],
        provides: { preview_provider: SyrusRails::PreviewProvider }
      )
    end
  end

  after { Syrus::PluginRegistry.reset! }

  it "detects a polyglot repo across both :prepare_detector and :preview_provider" do
    write("Gemfile", "")
    write("config/application.rb", "")
    write("bin/rails", "")
    write("package.json", "{}")
    write("package-lock.json", "{}")

    expect(described_class.for(@dir)).to contain_exactly("ruby", "syrus-rails", "javascript")
  end

  it "only includes the language plugin when the framework signal is absent" do
    write("Gemfile", "")

    expect(described_class.for(@dir)).to contain_exactly("ruby")
  end

  it "returns an empty array when nothing matches" do
    expect(described_class.for(@dir)).to eq([])
  end

  describe "instance disabling", :reset_plugin_registry do
    around do |ex|
      Syrus::PluginRegistry.reset!
      ex.run
      Syrus::PluginRegistry.reset!
    end

    it "excludes a plugin the operator has disabled even when its files match" do
      detector = Class.new { include Syrus::Plugin::PrepareDetector }
      detector.define_singleton_method(:detect?) { |repo_path| File.exist?(File.join(repo_path, "go.mod")) }
      detector.define_singleton_method(:prepare_commands) { |_repo_path| [ "go mod download" ] }

      Syrus::PluginRegistry.register(
        name: "test_go", version: "1.0.0",
        provides: { prepare_detector: detector }
      )
      write("go.mod", "")
      PluginRecord.find_by!(name: "test_go").update!(enabled: false)

      expect(described_class.for(@dir)).to eq([])
    end
  end
end
