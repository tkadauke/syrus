class AddRetirementFieldsToInsightSuggestions < ActiveRecord::Migration[8.1]
  def change
    add_column :insight_suggestions, :retired_at, :datetime unless column_exists?(:insight_suggestions, :retired_at)
    add_column :insight_suggestions, :retired_reason, :text unless column_exists?(:insight_suggestions, :retired_reason)

    unless column_exists?(:insight_suggestions, :superseded_by_insight_id)
      add_reference :insight_suggestions, :superseded_by_insight, null: true, foreign_key: { to_table: :insight_suggestions }
    end

    unless column_exists?(:insight_suggestions, :superseded_by_job_id)
      add_reference :insight_suggestions, :superseded_by_job, null: true, foreign_key: { to_table: :jobs }
    end
  end
end
