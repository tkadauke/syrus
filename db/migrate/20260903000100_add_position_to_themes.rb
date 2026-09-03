class AddPositionToThemes < ActiveRecord::Migration[8.1]
  def up
    add_column :themes, :position, :integer unless column_exists?(:themes, :position)
    add_index :themes, [ :owner_user_id, :position ], name: "index_themes_on_owner_user_id_and_position" unless index_exists?(:themes, [ :owner_user_id, :position ], name: "index_themes_on_owner_user_id_and_position")
  end

  def down
    remove_index :themes, name: "index_themes_on_owner_user_id_and_position" if index_exists?(:themes, [ :owner_user_id, :position ], name: "index_themes_on_owner_user_id_and_position")
    remove_column :themes, :position if column_exists?(:themes, :position)
  end
end
