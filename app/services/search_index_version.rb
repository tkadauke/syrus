module SearchIndexVersion
  TABLE_NAME = "search_index_metadata"

  module_function

  def current(key)
    return nil unless table_exists?

    SearchRecord.connection.select_value(
      "SELECT value FROM #{TABLE_NAME} WHERE key = ?",
      "SearchIndexVersion Read",
      [ bind(metadata_key(key)) ]
    )
  end

  def write!(key, version)
    ensure_table!
    SearchRecord.connection.exec_insert(
      "INSERT OR REPLACE INTO #{TABLE_NAME} (key, value) VALUES (?, ?)",
      "SearchIndexVersion Write",
      [ bind(metadata_key(key)), bind(version.to_s) ]
    )
  end

  def ensure_table!
    SearchRecord.connection.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS #{TABLE_NAME} (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    SQL
  end

  def table_exists?
    SyrusSearchDatabaseTasks.table_exists?(TABLE_NAME)
  end

  def metadata_key(key) = "content_version:#{key}"

  def bind(value)
    ActiveRecord::Relation::QueryAttribute.new(nil, value, ActiveRecord::Type::Value.new)
  end
end
