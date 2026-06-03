class AddProfileContactFieldsToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :profile_location, :string unless column_exists?(:users, :profile_location)
    add_column :users, :profile_company, :string unless column_exists?(:users, :profile_company)
    add_column :users, :profile_website, :string unless column_exists?(:users, :profile_website)
  end

  def down
    remove_column :users, :profile_website if column_exists?(:users, :profile_website)
    remove_column :users, :profile_company if column_exists?(:users, :profile_company)
    remove_column :users, :profile_location if column_exists?(:users, :profile_location)
  end
end
