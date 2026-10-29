class RenameCoworkerColorKeyToAccentHex < ActiveRecord::Migration[8.1]
  def up
    return unless column_exists?(:coworkers, :color_key)

    rename_column :coworkers, :color_key, :accent_hex
  end

  def down
    return unless column_exists?(:coworkers, :accent_hex)

    rename_column :coworkers, :accent_hex, :color_key
  end
end
