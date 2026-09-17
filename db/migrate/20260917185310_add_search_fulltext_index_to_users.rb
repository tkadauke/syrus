class AddSearchFulltextIndexToUsers < ActiveRecord::Migration[8.1]
  INDEX_NAME = "index_users_on_search_fields"

  def up
    return unless mysql?
    return if index_exists?(:users, [ :email_address, :name, :first_name, :last_name, :github_handle ], name: INDEX_NAME)

    add_index :users, [ :email_address, :name, :first_name, :last_name, :github_handle ],
      type: :fulltext, name: INDEX_NAME
  end

  def down
    return unless mysql?
    return unless index_exists?(:users, [ :email_address, :name, :first_name, :last_name, :github_handle ], name: INDEX_NAME)

    remove_index :users, name: INDEX_NAME
  end

  private

  def mysql?
    connection.adapter_name.downcase.include?("mysql")
  end
end
