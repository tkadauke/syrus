class AddLocaleToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :locale, :string unless column_exists?(:users, :locale)
    execute "UPDATE users SET locale = 'en' WHERE locale IS NULL"
    change_column_null :users, :locale, false if column_exists?(:users, :locale)
  end

  def down
    remove_column :users, :locale if column_exists?(:users, :locale)
  end
end
