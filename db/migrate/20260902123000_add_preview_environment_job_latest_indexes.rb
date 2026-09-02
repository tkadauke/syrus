class AddPreviewEnvironmentJobLatestIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :preview_environments,
      [ :job_id, :state, :created_at, :id ],
      name: "idx_preview_environments_job_state_latest",
      if_not_exists: true

    add_index :preview_environments,
      [ :job_id, :created_at, :id ],
      name: "idx_preview_environments_job_latest",
      if_not_exists: true
  end
end
