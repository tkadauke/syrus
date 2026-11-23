require "rails_helper"
require "syrus/plugin/family_contract_kit"

RSpec.describe Syrus::Plugin::FamilyContractCoverage do
  before do
    Syrus::Plugin::Family.reset!
    Syrus::Plugin::Family.define(:coverage_fixture) do
      shape :facet
      capability :items, composition: :collect, absent: [], tier: :provisional,
        context: Object, returns: Array
    end
  end

  after do
    Syrus::Plugin::Family.restore_built_ins!
  end

  def manifest(name, *providers, plugin_root: nil)
    declarations = providers.map do |provider|
      Syrus::Plugin::FamilyDeclaration.build(
        family: :coverage_fixture, provider:, provisional: %i[items]
      )
    end
    Syrus::Plugin::Manifest.new(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name:, version: "1.0.0", provides: {}, family_provides: declarations, metadata: {}, plugin_root:
    )
  end

  def with_plugin_spec(source)
    Dir.mktmpdir do |root|
      spec_root = Pathname(root).join("spec")
      FileUtils.mkdir_p(spec_root)
      spec_root.join("family_contract_spec.rb").write(source)
      yield root
    end
  end

  it "finds exact provider coverage from a plugin spec in an isolated process" do
    with_plugin_spec(<<~RUBY) do |root|
      # A comment mentioning "a valid coverage_fixture provider" is not coverage.
      it_behaves_like(
        'a valid coverage_fixture provider',
        plugin: 'one',
        provider: 'One::Provider',
        contexts: {},
        decline_contexts: {}
      )
    RUBY
      manifests = [ manifest("one", "One::Provider", "Two::Provider", plugin_root: root) ]

      expect(described_class.missing(manifests:)).to contain_exactly(
        have_attributes(plugin: "one", family: :coverage_fixture, provider: "Two::Provider")
      )
    end
  end

  it "rejects a shared example that does not identify an exact declaration" do
    manifests = [ manifest("one", "One::Provider") ]

    expect do
      described_class.declaration!(
        plugin: "one", family: :coverage_fixture, provider: "Other::Provider", manifests:
      )
    end.to raise_error(ArgumentError, /does not declare Other::Provider/)
  end
end
