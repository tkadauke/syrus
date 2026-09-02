class AddRepositoryPreviewLatestStableIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :preview_environments,
      [ :repository_id, :created_at, :id ],
      name: "idx_preview_environments_repository_latest",
      if_not_exists: true
  end
end
