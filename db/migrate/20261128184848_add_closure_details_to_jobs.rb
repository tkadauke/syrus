class AddClosureDetailsToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :closure_references, :json unless column_exists?(:jobs, :closure_references)
    add_column :jobs, :closure_note, :text unless column_exists?(:jobs, :closure_note)
  end

  def down
    remove_column :jobs, :closure_note if column_exists?(:jobs, :closure_note)
    remove_column :jobs, :closure_references if column_exists?(:jobs, :closure_references)
  end
end
