class AddContainedChatExecutionToAppSettings < ActiveRecord::Migration[8.1]
  # Defaults to "off" deliberately. Containerized chat execution depends on the
  # container_execution plugin being enabled AND a Docker launch environment
  # being configured on the workers; neither is true on a fresh install, and
  # wiring a hard requirement to a capability that ships disabled is what broke
  # every coworker chat turn on an instance where the plugin was off.
  def up
    return if column_exists?(:app_settings, :contained_chat_execution)

    add_column :app_settings, :contained_chat_execution, :string, default: "off", null: false
  end

  def down
    remove_column :app_settings, :contained_chat_execution if column_exists?(:app_settings, :contained_chat_execution)
  end
end
