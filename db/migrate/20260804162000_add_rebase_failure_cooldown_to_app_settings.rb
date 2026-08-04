class AddRebaseFailureCooldownToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :rebase_failure_cooldown_minutes, :integer, default: 60, null: false unless column_exists?(:app_settings, :rebase_failure_cooldown_minutes)
  end
end
