class AddSubmissionFailedAtToWorkflowVisualEvidences < ActiveRecord::Migration[8.1]
  def change
    add_column :workflow_visual_evidences, :submission_failed_at, :datetime unless column_exists?(:workflow_visual_evidences, :submission_failed_at)
  end
end
