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
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "ruby", version: Syrus::PluginApi.default_version, prepare_priority: 10,
        family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
          family: :ecosystem, provider: "Ruby::Ecosystem",
          implements: %i[detect_prepare grade_candidates grader_diagnostics review_criteria autofix dependency_audit focused_tests analyze_coverage],
          provisional: %i[affected_tests]
        ) ]
      )
    end

    unless Syrus::PluginRegistry.registered_names.include?("javascript")
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "javascript", version: Syrus::PluginApi.default_version, prepare_priority: 20,
        family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
          family: :ecosystem, provider: "JavaScript::Ecosystem",
          implements: %i[detect_prepare grade_candidates grader_diagnostics review_criteria autofix dependency_audit focused_tests]
        ) ]
      )
    end

    unless Syrus::PluginRegistry.registered_names.include?("syrus-rails")
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "syrus-rails", version: Syrus::PluginApi.default_version, depends_on: [ "ruby" ],
        provides: { preview_provider: SyrusRails::PreviewProvider }
      )
    end
  end

  after { Syrus::PluginRegistry.reset! }

  it "detects a polyglot repo across Ecosystem and preview providers" do
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
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "family-language", version: "1", family_provides: [ declaration ])
    end

    after do
      Syrus::PluginRegistry.reset!
      Syrus::Plugin::Family.restore_built_ins!
    end

    it "detects a plugin registered only through the family declaration" do
      write("family.lock")

      expect(described_class.for(@dir, repository: :repository)).to eq([ "family-language" ])
    end

    # Dispatch, the legacy bridge, and capability_providers only invoke a
    # capability through a conforming declaration. Detection is no exception:
    # a declaration whose provider breaks the family contract is withheld,
    # not called anyway.
    it "does not call a non-conforming declaration" do
      calls = []
      stub_const("NonConformingDetectorProvider", Class.new do
        define_singleton_method(:key) { :non_conforming }
        define_singleton_method(:display_name) { "Non-conforming" }
        define_singleton_method(:detect_prepare) { |context, _extra = nil| calls << context.repo_path; [ "prepare" ] }
      end)
      declaration = Syrus::Plugin::FamilyDeclaration.build(
        family: :detector_family, provider: "NonConformingDetectorProvider", implements: %i[detect_prepare]
      )
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "non-conforming", version: "1", family_provides: [ declaration ])
      write("family.lock")

      expect(described_class.for(@dir, repository: :repository)).to eq([ "family-language" ])
      expect(described_class.observed_for(@dir, repository: :repository)).to eq([ "family-language" ])
      expect(calls).to be_empty
    end

    it "keeps detecting the other plugins when a family provider fails to load" do
      stub_const("UnloadableDetectorProvider", Class.new do
        def self.key = :unloadable
        def self.display_name = "Unloadable"
        def self.detect_prepare(_context) = raise(LoadError, "cannot load such file -- unloadable/detector")
      end)
      declaration = Syrus::Plugin::FamilyDeclaration.build(
        family: :detector_family, provider: "UnloadableDetectorProvider", implements: %i[detect_prepare]
      )
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "unloadable", version: "1", family_provides: [ declaration ])
      write("family.lock")

      expect(described_class.for(@dir, repository: :repository)).to eq([ "family-language" ])
    end
  end
end
