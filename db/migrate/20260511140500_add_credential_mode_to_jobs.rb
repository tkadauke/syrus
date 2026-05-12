class AddCredentialModeToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :credential_mode, :string, null: false, default: "pat"
    add_index :jobs, :credential_mode
  end
end
