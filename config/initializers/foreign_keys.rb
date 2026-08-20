# Syrus intentionally does not enforce database-level foreign keys.
#
# The app relies on Rails associations, explicit cleanup, and reconciler-style
# repair paths instead. Database constraints make production migrations
# expensive and brittle on large operational tables, especially under MySQL
# where adding a foreign key can rewrite the table.
module SyrusForeignKeyPolicy
  def add_foreign_key(*)
    nil
  end
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::ConnectionAdapters::SchemaStatements.prepend(SyrusForeignKeyPolicy)
end
