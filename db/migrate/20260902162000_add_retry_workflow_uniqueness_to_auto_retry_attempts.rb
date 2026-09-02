class AddRetryWorkflowUniquenessToAutoRetryAttempts < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_auto_retry_attempts_unique_retry_workflow".freeze
  DUPLICATE_REASON = "duplicate retry_workflow scheduling suppressed by uniqueness migration".freeze

  def up
    unless column_exists?(:auto_retry_attempts, :retry_workflow_uniqueness_key)
      add_column :auto_retry_attempts, :retry_workflow_uniqueness_key, :string
    end

    dedupe_retry_workflow_attempts!
    backfill_retry_workflow_uniqueness_key!

    unless index_exists?(:auto_retry_attempts, [ :workflow_id, :retry_workflow_uniqueness_key ], name: INDEX_NAME)
      add_index :auto_retry_attempts,
                [ :workflow_id, :retry_workflow_uniqueness_key ],
                unique: true,
                name: INDEX_NAME
    end
  end

  def down
    remove_index :auto_retry_attempts, name: INDEX_NAME, if_exists: true
    remove_column :auto_retry_attempts, :retry_workflow_uniqueness_key if column_exists?(:auto_retry_attempts, :retry_workflow_uniqueness_key)
  end

  private

  def dedupe_retry_workflow_attempts!
    AutoRetryAttempt.reset_column_information

    duplicate_workflow_ids.each do |workflow_id|
      ids = AutoRetryAttempt
        .where(workflow_id: workflow_id, retry_kind: "retry_workflow", skipped_reason: nil)
        .order(:id)
        .pluck(:id)
      keep_id = ids.shift
      next unless keep_id && ids.any?

      AutoRetryAttempt.where(id: ids).update_all(skipped_reason: DUPLICATE_REASON, updated_at: Time.current)
    end
  end

  def backfill_retry_workflow_uniqueness_key!
    AutoRetryAttempt.reset_column_information
    AutoRetryAttempt.update_all(retry_workflow_uniqueness_key: nil)
    AutoRetryAttempt
      .where(retry_kind: "retry_workflow", skipped_reason: nil)
      .update_all(retry_workflow_uniqueness_key: "retry_workflow", updated_at: Time.current)
  end

  def duplicate_workflow_ids
    AutoRetryAttempt
      .where(retry_kind: "retry_workflow", skipped_reason: nil)
      .group(:workflow_id)
      .having("COUNT(*) > 1")
      .pluck(:workflow_id)
  end
end
