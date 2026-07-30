class AddSimpleModeReviewFields < ActiveRecord::Migration[8.1]
  def change
    add_column :epics, :user_approved_at, :datetime
    add_column :jobs, :auto_merge_enabled, :boolean, default: false, null: false
  end
end
