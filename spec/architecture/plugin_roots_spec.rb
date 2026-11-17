require "rails_helper"

RSpec.describe "plugin root discovery" do
  # Frontend assets remain repository-shaped until the separate frontend
  # relocation work. Everything else must discover Ruby plugins centrally.
  ALLOWLIST = {
    "app/services/admin/mcp_tool_card_coverage.rb" => "frontend tool-card discovery",
    "bin/check-migration-collisions" => "Git tree paths are necessarily repository-relative",
    "bin/rspec-focused" => "maps repository-relative changed files to bundled specs",
    "lib/syrus/plugin_roots.rb" => "the central built-in root definition"
  }.freeze

  it "keeps hardcoded plugin roots out of Ruby application and tooling code" do
    files = %w[app config lib].flat_map { |root| Rails.root.glob("#{root}/**/*.{rb,rake}") }
    files.concat(Rails.root.glob("bin/*").select { |path| path.file? && path.read(128).include?("ruby") })
    offenders = files.filter_map do |path|
      relative = path.relative_path_from(Rails.root).to_s
      next if ALLOWLIST.key?(relative)

      source = path.read
      relative if source.match?(/(?:join|glob)\(["']plugins(?:\/|["'])|["']plugins\/\*/)
    end

    expect(offenders).to be_empty, "hardcoded plugin roots (add only intentional built-in/frontend paths to ALLOWLIST):\n#{offenders.join("\n")}"
  end
end
