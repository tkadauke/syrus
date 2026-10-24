class AddPrFeedbackPollSelectedAtToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :pr_feedback_poll_selected_at, :datetime unless column_exists?(:jobs, :pr_feedback_poll_selected_at)
  end
end
