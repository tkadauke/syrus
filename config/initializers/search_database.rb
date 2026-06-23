require "fileutils"

Rails.application.config.after_initialize do
  db_config = SearchRecord.connection_db_config
  next unless db_config.adapter.casecmp("sqlite3").zero?

  database = db_config.database
  FileUtils.mkdir_p(File.dirname(database)) if database.present? && database != ":memory:"

  connection = SearchRecord.connection
  connection.execute("PRAGMA journal_mode=WAL")
  connection.execute("PRAGMA synchronous=NORMAL")
rescue ActiveRecord::StatementInvalid => e
  Rails.logger.warn("search_database: unable to set SQLite pragmas: #{e.message}")
rescue SystemCallError => e
  Rails.logger.warn("search_database: unable to prepare SQLite path: #{e.message}")
end
