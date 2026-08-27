class AddColorThemeToUsers < ActiveRecord::Migration[8.1]
  def change
    add_reference :users, :color_theme, null: true, foreign_key: { to_table: :themes } unless column_exists?(:users, :color_theme_id)
  end
end
