class CreateMysqlConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :mysql_connections, if_not_exists: true do |t|
      t.string :label, null: false
      t.string :host, null: false
      t.integer :port, null: false, default: 3306
      t.string :username, null: false
      t.string :default_database
      t.text :credentials
      t.boolean :agentic_access_enabled, null: false, default: false

      t.timestamps
    end
  end
end
