class AddRepairMetadataToProviderCircuitEvidence < ActiveRecord::Migration[8.1]
  def change
    add_column :provider_availability_evidences, :repair_status, :string, limit: 32 unless column_exists?(:provider_availability_evidences, :repair_status)
    add_column :provider_availability_evidences, :repair_reason, :text unless column_exists?(:provider_availability_evidences, :repair_reason)
    add_column :provider_availability_evidences, :repaired_at, :datetime unless column_exists?(:provider_availability_evidences, :repaired_at)
    add_reference :provider_availability_evidences, :repaired_by_user, foreign_key: { to_table: :users } unless column_exists?(:provider_availability_evidences, :repaired_by_user_id)

    add_column :run_failure_classifications, :repair_status, :string, limit: 32 unless column_exists?(:run_failure_classifications, :repair_status)
    add_column :run_failure_classifications, :repair_reason, :text unless column_exists?(:run_failure_classifications, :repair_reason)
    add_column :run_failure_classifications, :repaired_at, :datetime unless column_exists?(:run_failure_classifications, :repaired_at)
    add_reference :run_failure_classifications, :repaired_by_user, foreign_key: { to_table: :users } unless column_exists?(:run_failure_classifications, :repaired_by_user_id)

    unless index_exists?(:provider_availability_evidences, [ :provider, :status, :repair_status, :observed_at ], name: "idx_provider_evidence_circuit_repair")
      add_index :provider_availability_evidences, [ :provider, :status, :repair_status, :observed_at ], name: "idx_provider_evidence_circuit_repair"
    end
    unless index_exists?(:run_failure_classifications, [ :classification, :repair_status, :classified_at ], name: "idx_run_failure_circuit_repair")
      add_index :run_failure_classifications, [ :classification, :repair_status, :classified_at ], name: "idx_run_failure_circuit_repair"
    end
  end
end
