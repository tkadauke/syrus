class ChangeEncryptedUserSecretsToText < ActiveRecord::Migration[8.1]
  USER_SECRET_COLUMNS = %i[
    api_token
    claude_oauth_token
    codex_api_key
    github_token
  ].freeze
  API_TOKEN_INDEX = "index_users_on_api_token".freeze

  def up
    remove_api_token_index

    USER_SECRET_COLUMNS.each do |column|
      change_column :users, column, :text if column_exists?(:users, column) && column_type(column) != :text
    end

    add_api_token_index
  end

  def down
    remove_api_token_index

    USER_SECRET_COLUMNS.each do |column|
      change_column :users, column, :string if column_exists?(:users, column) && column_type(column) != :string
    end

    add_api_token_index
  end

  private

  def column_type(column)
    connection.columns(:users).find { |c| c.name == column.to_s }&.type
  end

  def remove_api_token_index
    remove_index :users, name: API_TOKEN_INDEX if index_exists?(:users, name: API_TOKEN_INDEX)
  end

  def add_api_token_index
    return unless column_exists?(:users, :api_token)

    if mysql?
      unless index_exists?(:users, :api_token, name: API_TOKEN_INDEX)
        add_index :users, :api_token, unique: true, name: API_TOKEN_INDEX, length: 768
      end
    else
      unless index_exists?(:users, :api_token, name: API_TOKEN_INDEX)
        add_index :users, :api_token, unique: true, name: API_TOKEN_INDEX
      end
    end
  end

  def mysql?
    connection.adapter_name.downcase.include?("mysql")
  end
end
