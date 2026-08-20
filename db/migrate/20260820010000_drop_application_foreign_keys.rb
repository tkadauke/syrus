class DropApplicationForeignKeys < ActiveRecord::Migration[8.1]
  def up
    tables.each do |table|
      foreign_keys(table).each do |foreign_key|
        remove_foreign_key table, name: foreign_key.name
      end
    end
  end

  def down
    # Intentionally irreversible. Syrus does not use database-level foreign keys.
  end

  private

  def tables
    connection.tables - [ "schema_migrations", "ar_internal_metadata" ]
  end
end
