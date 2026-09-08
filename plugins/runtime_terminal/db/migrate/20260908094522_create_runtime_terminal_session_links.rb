class CreateRuntimeTerminalSessionLinks < ActiveRecord::Migration[8.1]
  def up
    create_table :runtime_terminal_session_links, if_not_exists: true do |t|
      t.references :runtime_session, null: false, index: { unique: true }
      t.bigint :terminal_session_id, null: false

      t.timestamps
    end

    add_index :runtime_terminal_session_links, :terminal_session_id, unique: true unless index_exists?(:runtime_terminal_session_links, :terminal_session_id)
  end

  def down
    drop_table :runtime_terminal_session_links, if_exists: true
  end
end
