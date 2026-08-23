class AddShowWorkUnitDebugToAppSettings < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:app_settings, :show_work_unit_debug)

    add_column :app_settings, :show_work_unit_debug, :boolean, null: false, default: false
  end
end
