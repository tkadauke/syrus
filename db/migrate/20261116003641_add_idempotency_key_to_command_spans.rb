class AddIdempotencyKeyToCommandSpans < ActiveRecord::Migration[8.1]
  def up
    add_column :command_spans, :idempotency_key, :string unless column_exists?(:command_spans, :idempotency_key)
    unless index_exists?(:command_spans, name: "idx_command_spans_run_idempotency")
      add_index :command_spans, [ :run_id, :idempotency_key ], unique: true,
                name: "idx_command_spans_run_idempotency"
    end
  end

  def down
    remove_index :command_spans, name: "idx_command_spans_run_idempotency" if index_exists?(:command_spans, name: "idx_command_spans_run_idempotency")
    remove_column :command_spans, :idempotency_key if column_exists?(:command_spans, :idempotency_key)
  end
end
