module MysqlDbBrowser
  class QueryClassification
    MAXIMUM = {
      operation: "mysql.query/execute@v1",
      effects: %i[network_read confidential_read credential_use external_write privilege_change operational destructive irreversible],
      risk: :critical,
      confidence: :ambiguous
    }.freeze

    class Read
      PATTERN = /\A(?:SELECT|SHOW|DESCRIBE|DESC|EXPLAIN)\b/i
      def self.match?(sql) = sql.match?(PATTERN) && !sql.match?(/\bINTO\s+(?:OUTFILE|DUMPFILE)\b/i)
      def self.result = { operation: "mysql.query/read@v1", effects: %i[network_read confidential_read credential_use], risk: :medium, confidence: :certain }
    end

    class Write
      PATTERN = /\A(?:INSERT|UPDATE|DELETE|REPLACE|LOAD)\b/i
      def self.match?(sql) = sql.match?(PATTERN)
      def self.result = { operation: "mysql.query/write@v1", effects: %i[credential_use external_write], risk: :high, confidence: :certain }
    end

    class Schema
      PATTERN = /\A(?:CREATE|ALTER|DROP|TRUNCATE|RENAME)\b/i
      def self.match?(sql) = sql.match?(PATTERN)
      def self.result = { operation: "mysql.query/schema_change@v1", effects: %i[credential_use external_write destructive], risk: :critical, confidence: :certain }
    end

    class Administrative
      PATTERN = /\A(?:GRANT|REVOKE|SET|KILL|FLUSH|RESET|SHUTDOWN|INSTALL|UNINSTALL)\b/i
      def self.match?(sql) = sql.match?(PATTERN)
      def self.result = { operation: "mysql.query/administer@v1", effects: %i[credential_use privilege_change operational destructive irreversible], risk: :critical, confidence: :certain }
    end

    STRATEGIES = [ Administrative, Schema, Write, Read ].freeze

    def self.call(arguments)
      sql = arguments.to_h.with_indifferent_access[:sql].to_s.strip
      return MAXIMUM if sql.blank? || sql.match?(/\/\*!/) || sql.match?(/\AWITH\b/i) || sql.include?(";")

      STRATEGIES.find { |strategy| strategy.match?(sql) }&.result || MAXIMUM
    end
  end
end
