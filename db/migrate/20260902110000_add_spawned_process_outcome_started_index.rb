class AddSpawnedProcessOutcomeStartedIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :spawned_processes,
              [ :outcome, :started_at ],
              name: "idx_spawned_processes_outcome_started",
              if_not_exists: true
  end
end
