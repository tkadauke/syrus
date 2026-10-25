class CreateHandles < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BATCH_SIZE = 500
  HANDLE_MAX_LENGTH = 32

  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  class MigrationHandle < ActiveRecord::Base
    self.table_name = "handles"
  end

  def up
    unless table_exists?(:handles)
      create_table :handles do |t|
        t.string :handle, null: false, collation: sqlite? ? "NOCASE" : nil
        t.string :owner_type
        t.bigint :owner_id
        t.datetime :created_at, null: false
      end
    end
    add_index :handles, :handle, unique: true unless index_exists?(:handles, :handle, unique: true)
    unless index_exists?(:handles, [ :owner_type, :owner_id ], unique: true)
      add_index :handles, [ :owner_type, :owner_id ], unique: true
    end

    MigrationHandle.reset_column_information
    MigrationHandle.create_with(created_at: Time.current).find_or_create_by!(handle: "syrus")
    MigrationUser.reset_column_information
    MigrationUser.in_batches(of: BATCH_SIZE) do |users|
      users.select(:id, :github_handle, :email_address).each do |user|
        next if MigrationHandle.exists?(owner_type: "User", owner_id: user.id)

        create_user_handle!(user)
      end
    end
  end

  def down
    drop_table :handles, if_exists: true
  end

  private

  def create_user_handle!(user)
    base = normalize(user.github_handle.presence || user.email_address.to_s.split("@", 2).first)
    suffix = nil
    loop do
      MigrationHandle.create!(handle: with_suffix(base, suffix), owner_type: "User", owner_id: user.id, created_at: Time.current)
      break
    rescue ActiveRecord::RecordNotUnique
      suffix = suffix ? suffix + 1 : 2
    end
  end

  def normalize(value)
    normalized = value.to_s.downcase.gsub(/[^a-z0-9_-]+/, "-").gsub(/\A[-_]+|[-_]+\z/, "")
    normalized = "user" if normalized.length < 3
    normalized.first(HANDLE_MAX_LENGTH)
  end

  def with_suffix(base, number)
    return base unless number

    suffix = "-#{number}"
    "#{base.first(HANDLE_MAX_LENGTH - suffix.length)}#{suffix}"
  end

  def sqlite?
    connection.adapter_name.match?(/sqlite/i)
  end
end
