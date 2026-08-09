class AddWebauthnIdToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :webauthn_id, :string unless column_exists?(:users, :webauthn_id)

    User.find_each { |u| u.update_columns(webauthn_id: SecureRandom.urlsafe_base64(32)) }

    change_column_null :users, :webauthn_id, false
    add_index :users, :webauthn_id, unique: true unless index_exists?(:users, :webauthn_id)
  end

  def down
    remove_index :users, :webauthn_id if index_exists?(:users, :webauthn_id)
    remove_column :users, :webauthn_id if column_exists?(:users, :webauthn_id)
  end
end
