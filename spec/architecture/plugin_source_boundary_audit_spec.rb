require "rails_helper"
require "open3"
require "tmpdir"

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

  # app/assets/builds/spa.js is gitignored but present for anyone who has run
  # a frontend build, and its minified contents match short plugin names.
  # Scanning it turned a clean checkout into a failing audit.
  #
  # This used to write the fixture into the real app/services and delete it in
  # an ensure block. The audit only skips comment-only lines, so the fixture had
  # to be executable code -- and `SyrusDev::SqlExplain.call` at the top level of
  # a file under an autoload path is a landmine for every other process: any
  # Rails boot that eager-loaded while it existed ran it and died on
  # "missing keyword: :sql", and any spec globbing app/ raced its deletion and
  # died on ENOENT. Both showed up as unrelated failures in parallel runs and
  # in CI. Build the checkout the audit looks at instead, so nothing is ever
  # written into the tree the rest of the suite is reading.
  it "ignores untracked files under the core roots", :requires_git_checkout do
    Dir.mktmpdir do |dir|
      root = Pathname.new(dir)
      services = root.join("app/services")
      services.mkpath
      services.join("tracked_core_file.rb").write("Rails.logger.info('ok')\n")
      services.join("untracked_core_file.rb").write("SyrusDev::SqlExplain.call(sql: 'select 1')\n")
      # The audit reads manifests from <root>/plugins; point that at the real
      # ones so SyrusDev is a plugin it actually knows about.
      File.symlink(Rails.root.join("plugins").to_s, root.join("plugins").to_s)

      Open3.capture2("git", "-C", dir, "init", "-q")
      Open3.capture2("git", "-C", dir, "add", "app/services/tracked_core_file.rb")

      audit = Admin::PluginSourceBoundaryAudit.new(root: root)
      expect(audit.core_violations).to eq([])

      # ...and the file is skipped for being untracked, not because the scan
      # found nothing to match. Tracking it surfaces the same reference.
      Open3.capture2("git", "-C", dir, "add", "app/services/untracked_core_file.rb")
      tracked_audit = Admin::PluginSourceBoundaryAudit.new(root: root)
      expect(tracked_audit.core_violations.map(&:message)).to include(/untracked_core_file\.rb/)
    end
  end

  it "allows plugin-to-plugin references only through declared dependencies" do
    expect(audit.plugin_violations.map(&:message)).to eq([])
  end
end
