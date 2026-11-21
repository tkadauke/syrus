require "rails_helper"

RSpec.describe LocalBackups::SqliteSnapshot do
  it "creates a consistent online snapshot while writes continue" do
    Dir.mktmpdir do |directory|
      source = File.join(directory, "source.sqlite3")
      destination = File.join(directory, "snapshot.sqlite3")
      database = SQLite3::Database.new(source)
      database.execute("PRAGMA journal_mode=WAL")
      database.execute("CREATE TABLE events (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
      database.execute("INSERT INTO events(value) VALUES ('before')")
      writer = Thread.new do
        connection = SQLite3::Database.new(source)
        50.times { |index| connection.execute("INSERT INTO events(value) VALUES (?)", "during-#{index}") }
        connection.close
      end

      result = described_class.new(source:).create(destination)
      writer.join
      snapshot = SQLite3::Database.new(destination, readonly: true)

      expect(result.integrity).to eq("ok")
      expect(snapshot.get_first_value("PRAGMA integrity_check")).to eq("ok")
      expect(snapshot.get_first_value("SELECT COUNT(*) FROM events")).to be_between(1, 51)
    ensure
      snapshot&.close
      database&.close
      writer&.join
    end
  end
end
