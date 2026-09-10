class AddProjectIdToPreviewEnvironments < ActiveRecord::Migration[8.1]
  def change
    add_column :preview_environments, :project_id, :string unless column_exists?(:preview_environments, :project_id)
    unless index_exists?(:preview_environments, [ :job_id, :project_id, :created_at, :id ], name: "idx_preview_environments_job_project_latest")
      add_index :preview_environments, [ :job_id, :project_id, :created_at, :id ],
        name: "idx_preview_environments_job_project_latest"
    end
  end
end
