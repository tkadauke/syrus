class AddInvestigationToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :investigation, :boolean, default: false, null: false unless column_exists?(:jobs, :investigation)
  end
end
