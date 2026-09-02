class AddRepositoryPreviewLatestIndex < ActiveRecord::Migration[8.1]
  def change
    return if index_exists?(:preview_environments, [ :repository_id, :created_at ], name: "index_preview_environments_on_repository_id_and_created_at")

    add_index :preview_environments,
      [ :repository_id, :created_at ],
      name: "index_preview_environments_on_repository_id_and_created_at"
  end
end
