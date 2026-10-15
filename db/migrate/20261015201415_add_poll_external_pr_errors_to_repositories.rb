class AddPollExternalPrErrorsToRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :poll_external_pr_errors, :json unless column_exists?(:repositories, :poll_external_pr_errors)
  end
end
