class AddAutoApproveModes < ActiveRecord::Migration[8.1]
  def change
    add_column :epics, :auto_approve_mode, :string, default: "never", null: false
    add_column :scheduled_tasks, :auto_approve_mode, :string, default: "never", null: false
    add_column :repositories, :auto_approve_mode, :string, default: "never", null: false
    add_column :users, :auto_approve_mode, :string, default: "never", null: false
  end
end
