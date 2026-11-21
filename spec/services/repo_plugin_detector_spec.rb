require "rails_helper"
require "tmpdir"

RSpec.describe RepoPluginDetector, requires_plugin: %w[ruby javascript rails] do
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
        name: "ruby", version: Syrus::PluginApi.default_version, prepare_priority: 10,
        provides: { prepare_detector: Ruby::PrepareDetector }
      )
    end

    unless Syrus::PluginRegistry.registered_names.include?("javascript")
      Syrus::PluginRegistry.register(
        name: "javascript", version: Syrus::PluginApi.default_version, prepare_priority: 20,
        provides: { prepare_detector: JavaScript::PrepareDetector }
      )
    end

    unless Syrus::PluginRegistry.registered_names.include?("syrus-rails")
      Syrus::PluginRegistry.register(
        name: "syrus-rails", version: Syrus::PluginApi.default_version, depends_on: [ "ruby" ],
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

    # The whole point of the widened pass: a disabled plugin is exactly the one
    # that needs a way to say "this repository looks like me".
    it "still observes a disabled plugin whose files match, so it can be recommended" do
      detector = Class.new { include Syrus::Plugin::PrepareDetector }
      detector.define_singleton_method(:detect?) { |repo_path| File.exist?(File.join(repo_path, "go.mod")) }
      detector.define_singleton_method(:prepare_commands) { |_repo_path| [ "go mod download" ] }

      Syrus::PluginRegistry.register(name: "test_go", version: "1.0.0", provides: { prepare_detector: detector })
      write("go.mod", "")
      PluginRecord.find_by!(name: "test_go").update!(enabled: false)

      expect(described_class.observed_for(@dir)).to eq([ "test_go" ])
    end

    it "keeps a raising detector from taking the rest of the pass with it" do
      exploding = Class.new { include Syrus::Plugin::PrepareDetector }
      exploding.define_singleton_method(:detect?) { |_repo_path| raise "boom" }
      exploding.define_singleton_method(:prepare_commands) { |_repo_path| [] }

      working = Class.new { include Syrus::Plugin::PrepareDetector }
      working.define_singleton_method(:detect?) { |repo_path| File.exist?(File.join(repo_path, "go.mod")) }
      working.define_singleton_method(:prepare_commands) { |_repo_path| [] }

      Syrus::PluginRegistry.register(name: "test_boom", version: "1.0.0", provides: { prepare_detector: exploding })
      Syrus::PluginRegistry.register(name: "test_go", version: "1.0.0", provides: { prepare_detector: working })
      write("go.mod", "")

      expect(described_class.observed_for(@dir)).to eq([ "test_go" ])
    end
  end

  context "with a language-support family", :reset_plugin_registry do
    before do
      Syrus::PluginRegistry.reset!
      Syrus::Plugin::Family.define(:detector_family) do
        shape :facet
        indicates_language_support capability: :detect_prepare
        capability :detect_prepare, composition: :collect, absent: [], tier: :stable,
          context: Syrus::Plugin::Context::RepoContext, returns: Array
      end
      provider = Class.new do
        def self.key = :family_language
        def self.display_name = "Family language"
        def self.detect_prepare(context)
          File.exist?(File.join(context.repo_path, "family.lock")) && context.repository == :repository ? [ "prepare" ] : []
        end
      end
      stub_const("DetectorFamilySpecProvider", provider)
      declaration = Syrus::Plugin::FamilyDeclaration.build(
        family: :detector_family, provider: "DetectorFamilySpecProvider", implements: %i[detect_prepare]
      )
      Syrus::PluginRegistry.register(name: "family-language", version: "1", family_provides: [ declaration ])
    end

    after do
      Syrus::PluginRegistry.reset!
      Syrus::Plugin::Family.restore_built_ins!
    end

    it "detects a plugin registered only through the family declaration" do
      write("family.lock")

      expect(described_class.for(@dir, repository: :repository)).to eq([ "family-language" ])
    end

    it "detects family-only and legacy-only language plugins together" do
      legacy = Class.new { include Syrus::Plugin::PrepareDetector }
      legacy.define_singleton_method(:detect?) { |repo_path| File.exist?(File.join(repo_path, "legacy.lock")) }
      legacy.define_singleton_method(:prepare_commands) { |_repo_path| [ "legacy prepare" ] }
      Syrus::PluginRegistry.register(
        name: "legacy-language", version: "1", provides: { prepare_detector: legacy }
      )
      write("family.lock")
      write("legacy.lock")

      expect(described_class.for(@dir, repository: :repository))
        .to contain_exactly("family-language", "legacy-language")
    end
  end
end
