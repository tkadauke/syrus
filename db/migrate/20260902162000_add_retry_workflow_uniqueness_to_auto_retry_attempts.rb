class AddRetryWorkflowUniquenessToAutoRetryAttempts < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_auto_retry_attempts_unique_retry_workflow".freeze
  DUPLICATE_REASON = "duplicate retry_workflow scheduling suppressed by uniqueness migration".freeze

  def up
    dedupe_retry_workflow_attempts!

    add_index :auto_retry_attempts,
              [ :workflow_id, :retry_kind ],
              unique: true,
              where: "retry_kind = 'retry_workflow' AND skipped_reason IS NULL",
              name: INDEX_NAME,
              if_not_exists: true
  end

  def down
    remove_index :auto_retry_attempts, name: INDEX_NAME, if_exists: true
  end

  private

  def dedupe_retry_workflow_attempts!
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

  def duplicate_workflow_ids
    AutoRetryAttempt
      .where(retry_kind: "retry_workflow", skipped_reason: nil)
      .group(:workflow_id)
      .having("COUNT(*) > 1")
      .pluck(:workflow_id)
  end
end
