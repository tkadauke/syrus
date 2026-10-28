require "rails_helper"

RSpec.describe "canonical Job visibility scope" do
  USER_FACING_GLOBS = [
    "app/controllers/api/v1/app/**/*.rb",
    "app/controllers/concerns/**/*.rb",
    "app/channels/**/*.rb",
    "app/services/app/**/*payload*.rb",
    "app/services/app/**/*serializer*.rb",
    "app/services/mcp/tools/{list,read,search}_*.rb",
    "plugins/*/app/controllers/api/v1/app/**/*.rb"
  ].freeze
  RAW_JOB_QUERY = /\bJob\.(?:all|where|find|find_by|joins|from|order|count|exists\?|select|includes)\b/
  RAW_JOB_ASSOCIATION_QUERY = /\b[a-zA-Z_]\w*\.jobs\.(?:where|includes|order|count|exists\?|to_a|pluck|map)\b/
  CANONICAL_SCOPE = /Job\.visible_to\(|Job\.accessible_to\(|policy_scope\(Job\)/

  it "rejects newly added user-facing Job reads that bypass the canonical scope" do
    bypasses = user_facing_files.flat_map do |path|
      lines = path.readlines
      lines.each_index.filter_map do |index|
        next unless lines[index].match?(RAW_JOB_QUERY) || lines[index].match?(RAW_JOB_ASSOCIATION_QUERY)

        context = lines[[ index - 4, 0 ].max..index].join
        next if context.match?(CANONICAL_SCOPE)

        "#{path.relative_path_from(Rails.root)}:#{index + 1}: #{lines[index].strip}"
      end
    end

    expect(bypasses).to be_empty, <<~MESSAGE
      User-facing Job queries must be derived from Job.visible_to (Job.accessible_to
      is its backward-compatible alias). If this is lifecycle-only work, keep it
      outside payload/controller serialization code.
      #{bypasses.join("\n")}
    MESSAGE
  end

  def user_facing_files
    USER_FACING_GLOBS.flat_map { |pattern| Rails.root.glob(pattern) }
      .reject { |path| path.to_s.include?("/api/v1/app/admin/") }
      .uniq
  end
end
