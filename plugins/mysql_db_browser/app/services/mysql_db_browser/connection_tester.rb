require "mysql2"

module MysqlDbBrowser
  # Attempts a lightweight Mysql2::Client connect against a connection's
  # parameters. Never persists anything - callers decide separately whether
  # to save a MysqlConnection record.
  class ConnectionTester
    CONNECT_TIMEOUT_SECONDS = 5

    class_attribute :client_factory, default: ->(options) { Mysql2::Client.new(**options) }

    def self.test(connection)
      new.test(
        host: connection.host,
        port: connection.port,
        username: connection.username,
        password: connection.password,
        database: connection.default_database
      )
    end

    def self.test_params(host:, port:, username:, password:, database: nil)
      new.test(host: host, port: port, username: username, password: password, database: database)
    end

    def test(host:, port:, username:, password:, database: nil)
      client = build_client(host: host, port: port, username: username, password: password, database: database)
      client.query("SELECT 1")

      { success: true }
    rescue Mysql2::Error => e
      { success: false, error: e.message }
    ensure
      client&.close
    end

    private

    def build_client(host:, port:, username:, password:, database:)
      self.class.client_factory.call(
        host: host,
        port: port,
        username: username,
        password: password,
        database: database.presence,
        connect_timeout: CONNECT_TIMEOUT_SECONDS,
        read_timeout: CONNECT_TIMEOUT_SECONDS
      )
    end
  end
end
