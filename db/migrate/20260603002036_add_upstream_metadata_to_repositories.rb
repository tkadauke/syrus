class AddUpstreamMetadataToRepositories < ActiveRecord::Migration[8.1]
  def up
    add_column :repositories, :upstream_owner, :string unless column_exists?(:repositories, :upstream_owner)
    add_column :repositories, :upstream_name, :string unless column_exists?(:repositories, :upstream_name)
    add_column :repositories, :upstream_default_branch, :string unless column_exists?(:repositories, :upstream_default_branch)
  end

  def down
    remove_column :repositories, :upstream_default_branch if column_exists?(:repositories, :upstream_default_branch)
    remove_column :repositories, :upstream_name if column_exists?(:repositories, :upstream_name)
    remove_column :repositories, :upstream_owner if column_exists?(:repositories, :upstream_owner)
  end
end
