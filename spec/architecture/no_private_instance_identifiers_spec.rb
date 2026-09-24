require "rails_helper"

# A comment that says "Regression for WF-29556" or "this was JOB-409's root
# cause" names a record in one private Syrus instance. It means nothing to
# anyone else reading the code, and it goes stale the moment that record is
# archived -- so the explanation the identifier was standing in for is simply
# lost. Write the explanation instead ("a production run storm", "the
# access-control work"). See "Repository hygiene" in CLAUDE.md.
#
# This guards comments only, where the check is unambiguous. Fixture values
# (`run_id: 149674`, `slug: "JOB-874"`) are not comments and are deliberately
# left alone; so is `docs/plans/**`, which is the designated home for
# instance-specific evidence.
RSpec.describe "private instance identifiers" do
  IDENTIFIER = /\b(?:JOB|EPIC|WF|RUN)-\d+/
  # Placeholder/format examples the docs and CLI help legitimately use.
  PLACEHOLDERS = %w[JOB-42 JOB-123 EPIC-42 EPIC-123 WF-42 RUN-42].freeze
  COMMENT = %r{^\s*(?:\#|//)\s}

  def source_files
    Dir.glob(Rails.root.join("{app,lib,spec,e2e,cli,plugins}/**/*.{rb,ts,tsx,go}"))
      .reject { |path| path.include?("/node_modules/") || path == __FILE__ }
  end

  it "never appear in comments" do
    offenders = source_files.flat_map do |file|
      relative = Pathname(file).relative_path_from(Rails.root).to_s

      File.readlines(file).each_with_index.filter_map do |line, index|
        next unless line.match?(COMMENT)

        found = line.scan(IDENTIFIER).reject { |token| PLACEHOLDERS.include?(token) }
        next if found.empty?

        "#{relative}:#{index + 1}: #{found.uniq.join(', ')} -- #{line.strip}"
      end
    end

    expect(offenders).to be_empty, <<~MESSAGE
      Comments name records in a private Syrus instance. Replace each identifier
      with the explanation it stands in for (see "Repository hygiene" in
      CLAUDE.md), e.g. "Regression for WF-29556:" -> "Regression:".

      #{offenders.join("\n")}
    MESSAGE
  end
end
