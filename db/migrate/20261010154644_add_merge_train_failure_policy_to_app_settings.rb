class AddMergeTrainFailurePolicyToAppSettings < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:app_settings, :merge_train_failure_policy)
      add_column :app_settings, :merge_train_failure_policy, :string, default: "restart", null: false
    end
  end
end
