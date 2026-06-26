class RemoveLayoutVersionFromUsers < ActiveRecord::Migration[8.1]
  def up
    remove_column :users, :layout_version if column_exists?(:users, :layout_version)
  end

  def down
    add_column :users, :layout_version, :string, default: "v1", null: false unless column_exists?(:users, :layout_version)
  end
end
