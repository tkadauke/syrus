require "rails_helper"

RSpec.describe "Plugin source boundaries" do
  subject(:audit) { Admin::PluginSourceBoundaryAudit.new }

  it "finds every bundled plugin manifest" do
    # A plugin is a Ruby gem; the gemspec is what makes it one. A directory may
    # instead hold only a Go CLI module (plugins/<name>/cli) ahead of the Ruby
    # extraction, which has no manifest for the audit to find.
    gem_dirs = Rails.root.join("plugins").children.select(&:directory?).select do |dir|
      Dir.glob(dir.join("*.gemspec").to_s).any?
    end.map { |dir| dir.basename.to_s }

    expect(audit.bundled_manifests.map(&:dir_name)).to match_array(gem_dirs)
  end

  it "declares only installed bundled plugin dependencies" do
    missing = audit.missing_dependencies.map do |source, dependency|
      "#{source} depends_on #{dependency}, but no bundled plugin manifest declares that name"
    end

    expect(missing).to eq([])
  end

  it "does not treat an optional dependency as a removal-forcing one" do
    # optionally_depends_on ends in "depends_on"; a naive scan folded the two
    # together and dragged optional dependents out with their provider.
    skip "test_insights is not installed" unless audit.bundled_manifest_names.include?("test_insights")

    removed = audit.removed_plugin_names_for("global_search")

    expect(removed).to include("global_search")
    expect(removed).not_to include("test_insights")
  end

  it "has an acyclic plugin dependency graph" do
    cycles = audit.graph.cycles.map { |cycle| cycle.join(" -> ") }

    expect(cycles).to eq([])
  end

  it "keeps core code behind plugin extension boundaries" do
    expect(audit.core_violations.map(&:message)).to eq([])
  end

  it "ignores untracked files under the core roots", :requires_git_checkout do
    # app/assets/builds/spa.js is gitignored but present for anyone who has run
    # a frontend build, and its minified contents match short plugin names.
    # Scanning it turned a clean checkout into a failing audit.
    untracked = Rails.root.join("app/services/plugin_boundary_untracked_fixture.rb")
    untracked.write("SyrusDev::SqlExplain.call\n")

    expect(Admin::PluginSourceBoundaryAudit.new.core_violations).to eq([])
  ensure
    untracked&.delete if untracked&.exist?
  end

  it "allows plugin-to-plugin references only through declared dependencies" do
    expect(audit.plugin_violations.map(&:message)).to eq([])
  end
end
