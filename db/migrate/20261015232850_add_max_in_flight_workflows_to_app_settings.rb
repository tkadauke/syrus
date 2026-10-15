class AddMaxInFlightWorkflowsToAppSettings < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:app_settings, :max_in_flight_workflows)

    add_column :app_settings, :max_in_flight_workflows, :integer, default: 0, null: false
  end

  def down
    remove_column :app_settings, :max_in_flight_workflows if column_exists?(:app_settings, :max_in_flight_workflows)
  end
end
