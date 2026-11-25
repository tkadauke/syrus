# Host admission is measured now; the prediction/usage choice it selected no
# longer exists.
class RemoveHostAdmissionPolicyFromAppSettings < ActiveRecord::Migration[8.1]
  def up
    remove_column :app_settings, :host_admission_policy if column_exists?(:app_settings, :host_admission_policy)
  end

  def down
    add_column :app_settings, :host_admission_policy, :string, default: "prediction", null: false unless column_exists?(:app_settings, :host_admission_policy)
  end
end
