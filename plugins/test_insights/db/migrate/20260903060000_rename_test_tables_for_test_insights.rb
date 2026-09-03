class RenameTestTablesForTestInsights < ActiveRecord::Migration[8.1]
  RENAMES = {
    test_runs: :test_insight_runs,
    test_cases: :test_insight_cases,
    test_identities: :test_insight_identities,
    test_identity_runtime_summaries: :test_insight_runtime_summaries
  }.freeze

  def up
    RENAMES.each do |from, to|
      next unless table_exists?(from)
      next if table_exists?(to)

      rename_table from, to
    end
  end

  def down
    RENAMES.each do |from, to|
      next unless table_exists?(to)
      next if table_exists?(from)

      rename_table to, from
    end
  end
end
