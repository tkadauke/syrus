class AddCoworkerEnvironmentPolicyToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :coworker_environment_policy, :json
  end
end
