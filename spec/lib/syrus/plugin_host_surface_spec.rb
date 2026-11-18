require "rails_helper"
require "tmpdir"

RSpec.describe Syrus::PluginHostSurface do
  def load_surface(contents)
    Dir.mktmpdir do |directory|
      path = Pathname.new(directory).join("surface.yml")
      path.write(contents)
      return described_class.new(path: path)
    end
  end

  it "loads valid entries and supports lookup" do
    surface = load_surface(<<~YAML)
      legacy_baseline: 1
      constants:
        - name: StableApi
          tier: public
          since: 1.2.0
          notes: The stable entry point.
        - name: OldApi
          tier: legacy
    YAML

    expect(surface.lookup("StableApi")).to have_attributes(tier: "public", since: "1.2.0")
    expect(surface.legacy_entries.map(&:name)).to eq([ "OldApi" ])
  end

  it "rejects unknown tiers" do
    expect do
      load_surface("legacy_baseline: 0\nconstants:\n  - name: HiddenApi\n    tier: internal\n")
    end.to raise_error(ArgumentError, /unknown tier.*HiddenApi/)
  end

  it "requires since for public entries" do
    expect do
      load_surface("legacy_baseline: 0\nconstants:\n  - name: StableApi\n    tier: public\n")
    end.to raise_error(ArgumentError, /public entries require since.*StableApi/)
  end

  it "rejects duplicate names" do
    expect do
      load_surface(<<~YAML)
        legacy_baseline: 2
        constants:
          - name: OldApi
            tier: legacy
          - name: OldApi
            tier: legacy
      YAML
    end.to raise_error(ArgumentError, /duplicate names.*OldApi/)
  end
end
