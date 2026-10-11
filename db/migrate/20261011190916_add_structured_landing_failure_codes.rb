class AddStructuredLandingFailureCodes < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :landing_failure_code, :string unless column_exists?(:jobs, :landing_failure_code)
    add_column :merge_trains, :failure_code, :string unless column_exists?(:merge_trains, :failure_code)

    add_index :jobs, :landing_failure_code unless index_exists?(:jobs, :landing_failure_code)
    add_index :merge_trains, :failure_code unless index_exists?(:merge_trains, :failure_code)
  end
end
