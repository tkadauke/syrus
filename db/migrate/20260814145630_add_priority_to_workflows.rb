class AddPriorityToWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :workflows, :priority, :string, default: "medium", null: false unless column_exists?(:workflows, :priority)
  end
end
