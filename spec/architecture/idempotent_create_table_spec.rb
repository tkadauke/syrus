require "rails_helper"

# Migrations are idempotent (docs/engineering/conventions: generate them with
# bin/rails generate migration and make them idempotent): a deploy that dies
# halfway must be able to run them again. A bare `create_table` raises "table
# already exists" on that rerun. Older migrations predate this check; it holds
# from the runtime image verification work on, where one slipped through
# beside its idempotent siblings.
RSpec.describe "create_table in migrations" do
  CHECKED_FROM = 20261126000000

  it "passes if_not_exists" do
    offenders = Dir[Rails.root.join("db/{,*_}migrate/*.rb")].filter_map do |path|
      version = File.basename(path)[/\A\d+/].to_i
      next if version < CHECKED_FROM

      lines = File.readlines(path).each_with_index.filter_map do |line, index|
        next unless line.match?(/\bcreate_table\b/) && !line.lstrip.start_with?("#")
        next if line.include?("if_not_exists: true")

        "#{Pathname.new(path).relative_path_from(Rails.root)}:#{index + 1}"
      end
      lines.presence
    end.flatten

    expect(offenders).to be_empty, "create_table without if_not_exists: true:\n#{offenders.join("\n")}"
  end
end
