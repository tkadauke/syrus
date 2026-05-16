class AddLandingQueueFields < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :approved_at, :datetime
    add_column :jobs, :landing_failure_reason, :text
    add_column :users, :landing_paused, :boolean, default: false, null: false

    add_index :jobs, [ :state, :approved_at, :id ]
    add_index :users, :landing_paused
  end
end
