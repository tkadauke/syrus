class AddRequestedImplementationStartToEpics < ActiveRecord::Migration[8.1]
  def change
    add_reference :epics,
      :implementation_start_requested_by_user,
      foreign_key: { to_table: :users },
      index: { name: "index_epics_on_implementation_start_requested_by_user_id" }
    add_column :epics, :implementation_start_requested_at, :datetime
  end
end
