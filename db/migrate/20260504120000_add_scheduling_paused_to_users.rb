class AddSchedulingPausedToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :scheduling_paused, :boolean, default: false, null: false
  end
end
