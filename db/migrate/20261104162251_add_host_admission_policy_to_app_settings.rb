class AddHostAdmissionPolicyToAppSettings < ActiveRecord::Migration[8.1]
  def change
    # Defaults to the existing prediction-based behaviour so the column
    # appearing changes nothing: the usage policy is opt-in per instance.
    add_column :app_settings, :host_admission_policy, :string, default: "prediction", null: false unless column_exists?(:app_settings, :host_admission_policy)
  end
end
