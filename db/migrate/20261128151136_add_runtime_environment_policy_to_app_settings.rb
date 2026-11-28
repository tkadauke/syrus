class AddRuntimeEnvironmentPolicyToAppSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :app_settings, :runtime_environment_policy, :json unless column_exists?(:app_settings, :runtime_environment_policy)
  end

  def down
    remove_column :app_settings, :runtime_environment_policy if column_exists?(:app_settings, :runtime_environment_policy)
  end
end
