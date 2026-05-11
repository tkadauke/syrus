class AddLastFeedbackAddressedAtToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :last_feedback_addressed_at, :datetime, if_not_exists: true
  end
end
