class AddRecoverableDiagnosticsToBrowserErrorEvents < ActiveRecord::Migration[8.1]
  def up
    add_column :browser_error_events, :error_cause, :json unless column_exists?(:browser_error_events, :error_cause)
    add_column :browser_error_events, :last_interaction, :json unless column_exists?(:browser_error_events, :last_interaction)
    add_column :browser_error_events, :resource_timings, :json unless column_exists?(:browser_error_events, :resource_timings)
    add_column :browser_error_events, :component_stack_unavailable_reason, :string unless column_exists?(:browser_error_events, :component_stack_unavailable_reason)
    add_column :browser_error_events, :correlation_id, :string unless column_exists?(:browser_error_events, :correlation_id)
    add_column :browser_error_events, :occurrence_count, :integer, default: 1, null: false unless column_exists?(:browser_error_events, :occurrence_count)
    add_column :browser_error_events, :burst_duration_ms, :integer, default: 0, null: false unless column_exists?(:browser_error_events, :burst_duration_ms)
    add_column :browser_error_events, :last_occurred_at, :datetime unless column_exists?(:browser_error_events, :last_occurred_at)
    add_column :browser_error_events, :recoverable, :boolean, default: false, null: false unless column_exists?(:browser_error_events, :recoverable)

    execute "UPDATE browser_error_events SET error_cause = '{}' WHERE error_cause IS NULL"
    execute "UPDATE browser_error_events SET last_interaction = '{}' WHERE last_interaction IS NULL"
    execute "UPDATE browser_error_events SET resource_timings = '[]' WHERE resource_timings IS NULL"
    change_column_null :browser_error_events, :error_cause, false
    change_column_null :browser_error_events, :last_interaction, false
    change_column_null :browser_error_events, :resource_timings, false
    execute "UPDATE browser_error_events SET last_occurred_at = occurred_at WHERE last_occurred_at IS NULL"
    change_column_null :browser_error_events, :last_occurred_at, false
    add_index :browser_error_events, :correlation_id unless index_exists?(:browser_error_events, :correlation_id)
  end

  def down
    remove_index :browser_error_events, :correlation_id if index_exists?(:browser_error_events, :correlation_id)
    %i[error_cause component_stack_unavailable_reason last_interaction resource_timings correlation_id occurrence_count burst_duration_ms last_occurred_at recoverable].each do |column|
      remove_column :browser_error_events, column if column_exists?(:browser_error_events, column)
    end
  end
end
