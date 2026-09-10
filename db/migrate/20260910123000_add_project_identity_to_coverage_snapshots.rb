class AddProjectIdentityToCoverageSnapshots < ActiveRecord::Migration[8.1]
  def change
    add_column :coverage_snapshots, :project_id, :string unless column_exists?(:coverage_snapshots, :project_id)
    add_column :coverage_snapshots, :project_label, :string unless column_exists?(:coverage_snapshots, :project_label)
    add_column :coverage_snapshots, :target_label, :string unless column_exists?(:coverage_snapshots, :target_label)

    unless index_exists?(:coverage_snapshots, [ :repository_id, :project_id, :branch, :created_at ], name: "idx_coverage_snapshots_project_branch")
      add_index :coverage_snapshots, [ :repository_id, :project_id, :branch, :created_at ],
        name: "idx_coverage_snapshots_project_branch"
    end
  end
end
