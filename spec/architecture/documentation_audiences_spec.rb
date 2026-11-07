# frozen_string_literal: true

RSpec.describe "documentation audiences" do
  let(:root) { Pathname.new(File.expand_path("../..", __dir__)) }
  let(:guidance) { root.join("CLAUDE.md").read }
  let(:workflow_config) { root.join(".syrus.yml").read }
  let(:engineering_index) { root.join("docs/engineering/README.md").read }

  it "keeps the cross-project searchable-doc rule aligned" do
    [guidance, engineering_index].each do |document|
      normalized = document.gsub(/\s+/, " ")

      expect(normalized).to include("searchable by chat and implementation agents working on any project")
      expect(normalized).to include("response compression")
      expect(normalized).to include("payload shapes")
      expect(normalized).to include("caching")
      expect(normalized).to include("polling")
    end

    expect(workflow_config).to include("Do not require searchable\n      harness docs for internal-only implementation changes")
  end

  it "routes internal documentation to existing engineering owners" do
    destinations = %w[
      conventions architecture maps operations decisions pitfalls
    ]

    destinations.each do |destination|
      expect(root.join("docs/engineering", destination, "README.md")).to exist
      expect(guidance).to include("docs/engineering/#{destination}/")
      expect(engineering_index).to include("`#{destination}/`")
    end

    plugin_guide = root.join("docs/engineering/conventions/plugins.md")
    expect(plugin_guide).to exist
    expect(guidance).to include("docs/engineering/conventions/plugins.md")
    expect(engineering_index).to include("`conventions/plugins.md`")
  end
end
