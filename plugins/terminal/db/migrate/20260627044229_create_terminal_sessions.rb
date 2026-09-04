class CreateTerminalSessions < ActiveRecord::Migration[8.1]
  def up
    create_table :terminal_sessions, if_not_exists: true do |t|
      t.timestamps
    end

    ensure_bigint_reference(:terminal_sessions, :user, null: false)
    ensure_bigint_reference(:terminal_sessions, :workflow, null: true)
    add_column :terminal_sessions, :name, :string, null: false unless column_exists?(:terminal_sessions, :name)
    unless column_exists?(:terminal_sessions, :working_directory)
      add_column :terminal_sessions, :working_directory, :string, null: false
    end
    add_column :terminal_sessions, :relay_address, :string unless column_exists?(:terminal_sessions, :relay_address)
    unless column_exists?(:terminal_sessions, :auth_token)
      add_column :terminal_sessions, :auth_token, :string, null: false
    end
    unless column_exists?(:terminal_sessions, :started_at)
      add_column :terminal_sessions, :started_at, :datetime, null: false
    end
    add_column :terminal_sessions, :finished_at, :datetime unless column_exists?(:terminal_sessions, :finished_at)
    add_column :terminal_sessions, :outcome, :string unless column_exists?(:terminal_sessions, :outcome)

    add_index :terminal_sessions, :user_id unless index_exists?(:terminal_sessions, :user_id)
    add_index :terminal_sessions, :workflow_id unless index_exists?(:terminal_sessions, :workflow_id)
    add_index :terminal_sessions, :finished_at unless index_exists?(:terminal_sessions, :finished_at)
    add_foreign_key :terminal_sessions, :users unless foreign_key_exists?(:terminal_sessions, :users)
    add_foreign_key :terminal_sessions, :workflows unless foreign_key_exists?(:terminal_sessions, :workflows)
  end

  def down
    remove_foreign_key :terminal_sessions, :workflows if foreign_key_exists?(:terminal_sessions, :workflows)
    remove_foreign_key :terminal_sessions, :users if foreign_key_exists?(:terminal_sessions, :users)
    remove_index :terminal_sessions, :finished_at if index_exists?(:terminal_sessions, :finished_at)
    remove_index :terminal_sessions, :workflow_id if index_exists?(:terminal_sessions, :workflow_id)
    remove_index :terminal_sessions, :user_id if index_exists?(:terminal_sessions, :user_id)
    remove_column :terminal_sessions, :outcome if column_exists?(:terminal_sessions, :outcome)
    remove_column :terminal_sessions, :finished_at if column_exists?(:terminal_sessions, :finished_at)
    remove_column :terminal_sessions, :started_at if column_exists?(:terminal_sessions, :started_at)
    remove_column :terminal_sessions, :auth_token if column_exists?(:terminal_sessions, :auth_token)
    remove_column :terminal_sessions, :relay_address if column_exists?(:terminal_sessions, :relay_address)
    remove_column :terminal_sessions, :working_directory if column_exists?(:terminal_sessions, :working_directory)
    remove_column :terminal_sessions, :name if column_exists?(:terminal_sessions, :name)
    remove_reference :terminal_sessions, :workflow if column_exists?(:terminal_sessions, :workflow_id)
    remove_reference :terminal_sessions, :user if column_exists?(:terminal_sessions, :user_id)
    drop_table :terminal_sessions, if_exists: true
  end

  private

  def ensure_bigint_reference(table, reference, null:)
    column_name = :"#{reference}_id"

    if column_exists?(table, column_name)
      column = connection.columns(table).find { |candidate| candidate.name == column_name.to_s }
      needs_bigint = column.type == :integer && column.limit != 8
      needs_nullability = column.null != null
      change_column table, column_name, :bigint, null: null if needs_bigint || needs_nullability
    else
      add_reference table, reference, type: :bigint, null:, index: false
    end
  end
end
