class AddAllowWritesToMysqlConnections < ActiveRecord::Migration[8.1]
  def change
    add_column :mysql_connections, :allow_writes, :boolean, default: false, null: false unless column_exists?(:mysql_connections, :allow_writes)
  end
end
