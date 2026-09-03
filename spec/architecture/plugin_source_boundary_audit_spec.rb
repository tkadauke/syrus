require "rails_helper"

RSpec.describe "Plugin source boundaries" do
  subject(:audit) { Admin::PluginSourceBoundaryAudit.new }

  it "finds every bundled plugin manifest" do
    plugin_dirs = Rails.root.join("plugins").children.select(&:directory?).map { |path| path.basename.to_s }

    expect(audit.bundled_manifests.map(&:dir_name)).to match_array(plugin_dirs - [ "README.md" ])
  end

  it "declares only installed bundled plugin dependencies" do
    missing = audit.missing_dependencies.map do |source, dependency|
      "#{source} depends_on #{dependency}, but no bundled plugin manifest declares that name"
    end

    expect(missing).to eq([])
  end

  it "has an acyclic plugin dependency graph" do
    cycles = audit.graph.cycles.map { |cycle| cycle.join(" -> ") }

    expect(cycles).to eq([])
  end

  it "keeps core code behind plugin extension boundaries" do
    expect(audit.core_violations.map(&:message)).to eq([])
  end

  it "allows plugin-to-plugin references only through declared dependencies" do
    expect(audit.plugin_violations.map(&:message)).to eq([])
  end
end
