module LocalBackups
  class DatabaseSnapshot
    DRIVERS = {
      "sqlite" => SqliteSnapshot,
      "mysql" => MysqlSnapshot
    }.freeze

    def self.for(connection: ActiveRecord::Base.connection, **options)
      adapter = connection.adapter_name.downcase
      driver = DRIVERS.find { |name, _| adapter.include?(name) }&.last
      raise Creator::UnsupportedDatabase, "local backup creation does not support #{connection.adapter_name}" unless driver

      driver.new(connection:, **options)
    end
  end
end
