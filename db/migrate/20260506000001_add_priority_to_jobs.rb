class AddPriorityToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :priority, :string, default: "medium", null: false unless column_exists?(:jobs, :priority)
  end
end
