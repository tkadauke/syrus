class AddRepairStatusRecentIndexToProviderAvailabilityEvidences < ActiveRecord::Migration[8.1]
  def change
    add_index :provider_availability_evidences,
              [ :user_id, :provider, :status, :repair_status, :observed_at, :id ],
              name: "idx_provider_evidence_user_status_repair_recent",
              if_not_exists: true
  end
end
