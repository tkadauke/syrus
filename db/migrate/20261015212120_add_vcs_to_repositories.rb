class AddVcsToRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :vcs, :string, default: "git", null: false unless column_exists?(:repositories, :vcs)
    add_index :repositories, [ :vcs, :archived_at, :id ], name: "idx_repositories_vcs_active_scan" unless index_exists?(:repositories, name: "idx_repositories_vcs_active_scan")
  end
end
