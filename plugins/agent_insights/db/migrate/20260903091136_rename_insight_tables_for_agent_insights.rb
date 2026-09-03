class RenameInsightTablesForAgentInsights < ActiveRecord::Migration[8.1]
  RENAMES = {
    insight_suggestions: :agent_insight_suggestions,
    insight_schedule_configs: :agent_insight_schedule_configs,
    insight_suggestion_audit_events: :agent_insight_audit_events
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
