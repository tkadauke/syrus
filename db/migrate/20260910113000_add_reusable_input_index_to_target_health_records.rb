class AddReusableInputIndexToTargetHealthRecords < ActiveRecord::Migration[8.1]
  def change
    columns = [
      :repository_id,
      :target_label,
      :input_fingerprint,
      :command_fingerprint,
      :environment_fingerprint,
      :checked_at,
      :created_at
    ]

    unless index_exists?(:target_health_records, columns, name: "idx_target_health_records_reusable_inputs")
      add_index :target_health_records, columns, name: "idx_target_health_records_reusable_inputs"
    end
  end
end
