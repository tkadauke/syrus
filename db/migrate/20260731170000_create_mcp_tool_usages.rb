class CreateMcpToolUsages < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_tool_usages do |t|
      t.string :surface, null: false
      t.string :provider
      t.string :session_id
      t.string :tool_use_id
      t.string :raw_tool_name, null: false
      t.string :server_name
      t.string :tool_name, null: false
      t.string :normalized_tool_name, null: false
      t.string :status, null: false
      t.boolean :error, null: false, default: false
      t.string :error_class
      t.string :error_message_summary, limit: 512
      t.integer :input_bytes
      t.integer :result_bytes
      t.datetime :started_at
      t.datetime :completed_at

      t.references :user, foreign_key: true
      t.references :repository, foreign_key: true
      t.references :job, foreign_key: true
      t.references :workflow, foreign_key: true
      t.references :run, foreign_key: true
      t.references :chat_session, foreign_key: true

      t.timestamps
    end

    add_index :mcp_tool_usages, [ :surface, :created_at ]
    add_index :mcp_tool_usages, [ :surface, :normalized_tool_name, :created_at ], name: "idx_mcp_tool_usages_surface_tool_window"
    add_index :mcp_tool_usages, [ :server_name, :normalized_tool_name, :created_at ], name: "idx_mcp_tool_usages_server_tool_window"
    add_index :mcp_tool_usages, [ :run_id, :tool_use_id ]
    add_index :mcp_tool_usages, [ :chat_session_id, :tool_use_id ]
  end
end
