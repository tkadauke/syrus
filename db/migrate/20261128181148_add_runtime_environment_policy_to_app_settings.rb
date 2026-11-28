class AddRuntimeEnvironmentPolicyToAppSettings < ActiveRecord::Migration[8.1]
  COLUMNS = {
    runtime_environment_policy: :json,
    runtime_image_registry_url: :string,
    runtime_image_registry_repository_prefix: :string,
    runtime_image_registry_builder_username: :string,
    runtime_image_registry_builder_password: :string,
    runtime_image_registry_worker_username: :string,
    runtime_image_registry_worker_password: :string,
    runtime_image_registry_admin_username: :string,
    runtime_image_registry_admin_password: :string
  }.freeze

  def up
    COLUMNS.each { |name, type| add_column(:app_settings, name, type) unless column_exists?(:app_settings, name) }
  end

  def down
    COLUMNS.each_key { |name| remove_column(:app_settings, name) if column_exists?(:app_settings, name) }
  end
end
