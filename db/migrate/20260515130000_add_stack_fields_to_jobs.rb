class AddStackFieldsToJobs < ActiveRecord::Migration[8.1]
  def change
    add_reference :jobs, :parent_job, null: true, foreign_key: { to_table: :jobs }
    add_column :jobs, :stack_base, :string, null: false, default: "auto"
    add_index :jobs, :stack_base
  end
end
