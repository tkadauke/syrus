class AddSimpleModeReviewFields < ActiveRecord::Migration[8.1]
  def change
    add_column :epics, :user_approved_at, :datetime unless column_exists?(:epics, :user_approved_at)
    add_column :jobs, :auto_merge_enabled, :boolean, default: false, null: false unless column_exists?(:jobs, :auto_merge_enabled)
  end
end
