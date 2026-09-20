class AddSingletonKeyToAppSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :app_settings, :singleton_key, :integer, default: 1, null: false unless column_exists?(:app_settings, :singleton_key)

    deduplicate_app_settings!

    unless check_constraint_exists?(:app_settings, name: "chk_app_settings_singleton_key")
      add_check_constraint :app_settings, "singleton_key = 1", name: "chk_app_settings_singleton_key"
    end

    unless index_exists?(:app_settings, :singleton_key, name: "index_app_settings_on_singleton_key")
      add_index :app_settings, :singleton_key, unique: true, name: "index_app_settings_on_singleton_key"
    end
  end

  def down
    if index_exists?(:app_settings, :singleton_key, name: "index_app_settings_on_singleton_key")
      remove_index :app_settings, name: "index_app_settings_on_singleton_key"
    end
    remove_check_constraint :app_settings, name: "chk_app_settings_singleton_key" if check_constraint_exists?(:app_settings, name: "chk_app_settings_singleton_key")
    remove_column :app_settings, :singleton_key if column_exists?(:app_settings, :singleton_key)
  end

  private

  def deduplicate_app_settings!
    ids = select_values("SELECT id FROM app_settings ORDER BY id ASC")
    return if ids.length <= 1

    keep_id = ids.first
    duplicate_ids = ids.drop(1)
    execute("DELETE FROM app_settings WHERE id IN (#{duplicate_ids.map { |id| quote(id) }.join(', ')})")
    execute("UPDATE app_settings SET singleton_key = 1 WHERE id = #{quote(keep_id)}")
  end
end
