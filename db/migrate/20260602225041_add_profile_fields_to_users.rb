class AddProfileFieldsToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :first_name, :string unless column_exists?(:users, :first_name)
    add_column :users, :last_name, :string unless column_exists?(:users, :last_name)
    add_column :users, :profile_bio, :text unless column_exists?(:users, :profile_bio)
    add_column :users, :profile_location, :string unless column_exists?(:users, :profile_location)
    add_column :users, :profile_company, :string unless column_exists?(:users, :profile_company)
    add_column :users, :profile_website, :string unless column_exists?(:users, :profile_website)
    add_column :users, :avatar_url, :string unless column_exists?(:users, :avatar_url)
  end

  def down
    remove_column :users, :avatar_url if column_exists?(:users, :avatar_url)
    remove_column :users, :profile_website if column_exists?(:users, :profile_website)
    remove_column :users, :profile_company if column_exists?(:users, :profile_company)
    remove_column :users, :profile_location if column_exists?(:users, :profile_location)
    remove_column :users, :profile_bio if column_exists?(:users, :profile_bio)
    remove_column :users, :last_name if column_exists?(:users, :last_name)
    remove_column :users, :first_name if column_exists?(:users, :first_name)
  end
end
