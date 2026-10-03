class AddDedupeIdentityToNotifications < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_notifications_dedupe_identity"

  def up
    unless column_exists?(:notifications, :repository_id)
      add_reference :notifications, :repository, null: true, foreign_key: false
    end

    add_column :notifications, :dedupe_key, :string, limit: 191 unless column_exists?(:notifications, :dedupe_key)

    unless index_exists?(:notifications, [ :user_id, :kind, :repository_id, :dedupe_key ], name: INDEX_NAME)
      add_index :notifications,
                [ :user_id, :kind, :repository_id, :dedupe_key ],
                unique: true,
                name: INDEX_NAME
    end
  end

  def down
    remove_index :notifications, name: INDEX_NAME if index_exists?(:notifications, name: INDEX_NAME)
    remove_reference :notifications, :repository, foreign_key: false if column_exists?(:notifications, :repository_id)
    remove_column :notifications, :dedupe_key if column_exists?(:notifications, :dedupe_key)
  end
end
