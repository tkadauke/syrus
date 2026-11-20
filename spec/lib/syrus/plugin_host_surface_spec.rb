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
        - name: OldApi
    YAML

    expect(surface.lookup("OldApi")).to have_attributes(name: "OldApi")
    expect(surface.legacy_entries.map(&:name)).to eq([ "OldApi" ])
  end

  it "rejects duplicate names" do
    expect do
      load_surface(<<~YAML)
        legacy_baseline: 2
        constants:
          - name: OldApi
          - name: OldApi
      YAML
    end.to raise_error(ArgumentError, /duplicate names.*OldApi/)
  end
end
