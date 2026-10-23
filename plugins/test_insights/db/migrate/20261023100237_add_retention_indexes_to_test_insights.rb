class AddRetentionIndexesToTestInsights < ActiveRecord::Migration[8.1]
  TABLES = %i[test_insight_cases test_insight_runs test_insight_isolated_repro_attempts].freeze

  def up
    TABLES.each do |table|
      add_index table, [ :created_at, :id ], name: index_name(table) unless index_exists?(table, [ :created_at, :id ], name: index_name(table))
    end
  end

  def down
    TABLES.each do |table|
      remove_index table, name: index_name(table) if index_exists?(table, [ :created_at, :id ], name: index_name(table))
    end
  end

  private

  def index_name(table)
    "idx_#{table.to_s.delete_prefix('test_insight_')}_retention"
  end
end
