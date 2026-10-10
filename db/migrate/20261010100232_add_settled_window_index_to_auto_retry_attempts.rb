class AddSettledWindowIndexToAutoRetryAttempts < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_auto_retry_attempts_settled_window".freeze
  COLUMNS = [ :updated_at, :performed_at, :skipped_reason ].freeze

  def up
    return if index_exists?(:auto_retry_attempts, COLUMNS, name: INDEX_NAME)

    add_index :auto_retry_attempts, COLUMNS, name: INDEX_NAME
  end

  def down
    return unless index_exists?(:auto_retry_attempts, COLUMNS, name: INDEX_NAME)

    remove_index :auto_retry_attempts, name: INDEX_NAME
  end
end
