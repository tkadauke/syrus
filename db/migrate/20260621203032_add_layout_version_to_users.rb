class AddLayoutVersionToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :layout_version, :string, default: "v1", null: false unless column_exists?(:users, :layout_version)
  end

  def down
    remove_column :users, :layout_version if column_exists?(:users, :layout_version)
  end
end
