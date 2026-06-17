class AddThemeToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :theme, :string, default: "light", null: false unless column_exists?(:users, :theme)
  end

  def down
    remove_column :users, :theme if column_exists?(:users, :theme)
  end
end
