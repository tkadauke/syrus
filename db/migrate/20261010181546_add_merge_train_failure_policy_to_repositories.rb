class AddMergeTrainFailurePolicyToRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :merge_train_failure_policy, :json unless column_exists?(:repositories, :merge_train_failure_policy)
  end
end
