require "rails_helper"

RSpec.describe "plugin root path ownership" do
  # These files intentionally inspect repository-owned source or frontend
  # assets. External frontend and CLI discovery are separate work.
  BUILT_IN_ONLY = %w[
    app/services/admin/mcp_tool_card_coverage.rb
    app/services/admin/plugin_source_boundary_audit.rb
    app/services/admin/plugin_ownership_audit.rb
  ].freeze

  it "keeps Ruby plugin filesystem discovery behind PluginRoots" do
    ruby_sources = Dir.glob(Rails.root.join("{app,config,lib,bin}/**/*.{rb,rake}"))
    ruby_executables = Dir.glob(Rails.root.join("bin/*")).select do |file|
      File.file?(file) && File.open(file, &:readline).start_with?("#!/usr/bin/env ruby")
    rescue EOFError
      false
    end
    files = ruby_sources + ruby_executables
    offenders = files.filter_map do |file|
      relative = Pathname.new(file).relative_path_from(Rails.root).to_s
      next if relative == "lib/plugin_roots.rb" || BUILT_IN_ONLY.include?(relative)

      line = File.readlines(file).find { |source| source.match?(/(?:join|glob)\([^\n]*["']plugins(?:\/|["'])/) }
      "#{relative}: #{line.strip}" if line
    end

    expect(offenders).to be_empty, "route plugin filesystem discovery through PluginRoots:\n#{offenders.join("\n")}"
  end
end
