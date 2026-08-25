class CreateMysqlQueryAudits < ActiveRecord::Migration[8.1]
  def change
    create_table :mysql_query_audits, if_not_exists: true do |t|
      t.references :mysql_connection, null: false
      t.references :user, null: false
      t.text :statement, null: false
      t.boolean :read_only, null: false, default: true
      t.boolean :success, null: false, default: true
      t.integer :row_count
      t.text :error_message
      t.integer :duration_ms

      t.timestamps
    end

    add_index :mysql_query_audits, [ :mysql_connection_id, :created_at ] unless index_exists?(:mysql_query_audits, [ :mysql_connection_id, :created_at ])
  end
end
