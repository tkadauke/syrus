# frozen_string_literal: true

# config/syrus_docs is searchable by agents on any project, so prose there must
# not point at Syrus-internal source or ops paths. Fenced code blocks are
# skipped because they hold user-facing `.syrus.yml` examples (for example
# `when_files_changed` globs or a `deploy.run: bin/deploy` command).
RSpec.describe "searchable harness docs internal path references" do
  FORBIDDEN_PATH = %r{app/frontend/[\w./-]+\.tsx?\b|eslint-rules/|\bbin/deploy\b}

  it "keeps internal source and ops paths out of prose" do
    offenders = Dir[Rails.root.join("config/syrus_docs/*.md")].flat_map do |file|
      in_fence = false
      File.readlines(file).each_with_index.filter_map do |line, index|
        in_fence = !in_fence if line.lstrip.start_with?("```")
        next if in_fence || line.lstrip.start_with?("```")

        "#{File.basename(file)}:#{index + 1}" if line.match?(FORBIDDEN_PATH)
      end
    end

    expect(offenders).to be_empty
  end
end
