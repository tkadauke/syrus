module SyrusDev
  class SqlExplain
    MAX_SQL_BYTES = 20_000
    DEFAULT_ANALYZE_TIMEOUT_MS = 1_000
    MAX_ANALYZE_TIMEOUT_MS = 5_000
    NON_READ_ONLY_KEYWORDS = %w[insert update delete replace alter create drop truncate call load grant revoke lock unlock].freeze
    ANALYZE_UNSAFE_FUNCTIONS = %w[get_lock release_lock sleep benchmark load_file].freeze

    Error = Class.new(StandardError)

    Result = Data.define(
      :adapter,
      :mode,
      :normalized_sql,
      :placeholder_substituted,
      :timeout_ms,
      :analyze_safe,
      :analyze_safety_reason,
      :rows,
      :json_plan,
      :warnings
    ) do
      def as_json(*)
        {
          adapter: adapter,
          mode: mode,
          normalized_sql: normalized_sql,
          placeholder_substituted: placeholder_substituted,
          timeout_ms: timeout_ms,
          analyze_safe: analyze_safe,
          analyze_safety_reason: analyze_safety_reason,
          rows: rows,
          json_plan: json_plan,
          warnings: warnings
        }
      end
    end

    class << self
      def call(sql:, analyze: false, timeout_ms: DEFAULT_ANALYZE_TIMEOUT_MS)
        new(sql: sql, analyze: analyze, timeout_ms: timeout_ms).call
      end
    end

    def initialize(sql:, analyze:, timeout_ms:)
      @sql = sql.to_s
      @analyze = ActiveModel::Type::Boolean.new.cast(analyze)
      @timeout_ms = normalized_timeout(timeout_ms)
    end

    def call
      validate!
      connection = ActiveRecord::Base.connection
      adapter = connection.adapter_name.to_s.downcase

      if adapter.include?("mysql")
        mysql_explain(connection, adapter)
      elsif analyze?
        raise Error, "EXPLAIN ANALYZE is only enabled for MySQL connections"
      else
        sqlite_explain(connection, adapter)
      end
    rescue ActiveRecord::ActiveRecordError => e
      raise Error.new(database_error_message(e)), cause: e
    end

    private

    attr_reader :sql, :timeout_ms

    def analyze?
      @analyze
    end

    def normalized_timeout(value)
      raw = Integer(value, exception: false) || DEFAULT_ANALYZE_TIMEOUT_MS
      [[raw, 1].max, MAX_ANALYZE_TIMEOUT_MS].min
    end

    def validate!
      raise Error, "SQL is required" if sql.blank?
      raise Error, "SQL is too large to explain safely" if sql.bytesize > MAX_SQL_BYTES
      tokens = executable_tokens
      raise Error, "Quoted SQL contains an ambiguous backslash escape" if @ambiguous_quote_escape
      raise Error, "Only a single statement can be explained" if tokens.include?(";")
      raise Error, "Only SELECT/CTE statements can be explained" unless %w[select with].include?(tokens.first)
      raise Error, "MySQL executable comments are not accepted for explain requests" if tokens.include?("/*!")
      raise Error, "Statement contains non-read-only SQL" if (tokens & NON_READ_ONLY_KEYWORDS).any?
      raise Error, "Statement contains user variables, which are not safe for EXPLAIN ANALYZE" if analyze? && tokens.include?("@")
      if analyze? && analyze_unsafe?
        raise Error, "Statement contains SQL that is not safe for EXPLAIN ANALYZE"
      end
    end

    def mysql_explain(connection, adapter)
      if analyze?
        with_mysql_statement_timeout(connection) do
          result(
            adapter: adapter,
            mode: "analyze",
            timeout_ms: timeout_ms,
            rows: select_rows(connection, "EXPLAIN ANALYZE #{normalized_sql}")
          )
        end
      else
        rows = select_rows(connection, "EXPLAIN FORMAT=JSON #{normalized_sql}")
        result(
          adapter: adapter,
          mode: "explain",
          timeout_ms: nil,
          rows: rows,
          json_plan: parse_json_plan(rows)
        )
      end
    end

    def sqlite_explain(connection, adapter)
      result(
        adapter: adapter,
        mode: "explain",
        timeout_ms: nil,
        rows: select_rows(connection, "EXPLAIN QUERY PLAN #{normalized_sql}"),
        warnings: [ "SQLite uses EXPLAIN QUERY PLAN; production MySQL plans can differ." ]
      )
    end

    def result(adapter:, mode:, timeout_ms:, rows:, json_plan: nil, warnings: [])
      analyze_safety = analyze_safety_for(adapter)
      Result.new(
        adapter: adapter,
        mode: mode,
        normalized_sql: normalized_sql,
        placeholder_substituted: placeholder_substituted?,
        timeout_ms: timeout_ms,
        analyze_safe: analyze_safety.fetch(:safe),
        analyze_safety_reason: analyze_safety.fetch(:reason),
        rows: rows,
        json_plan: json_plan,
        warnings: warnings
      )
    end

    def select_rows(connection, statement)
      connection.select_all(statement).to_a
    end

    def database_error_message(error)
      [
        "Could not explain SQL: #{error.message}.",
        "The stored sample SQL may be truncated or reference tables unavailable to this database;",
        "copy the full query from logs and try again."
      ].join(" ")
    end

    def parse_json_plan(rows)
      raw = rows.first&.values&.first
      JSON.parse(raw) if raw.present?
    rescue JSON::ParserError
      nil
    end

    def with_mysql_statement_timeout(connection)
      connection.execute("SET SESSION max_execution_time = #{timeout_ms}")
      yield
    ensure
      connection.execute("SET SESSION max_execution_time = 0") rescue nil
    end

    def normalized_sql
      @normalized_sql ||= sql.strip.gsub(/\?/, "NULL")
    end

    def placeholder_substituted?
      sql.include?("?")
    end

    def analyze_safety_for(adapter)
      return { safe: false, reason: "EXPLAIN ANALYZE is only enabled for MySQL connections." } unless adapter.include?("mysql")
      return { safe: false, reason: "Only SELECT/CTE statements can be analyzed." } unless %w[select with].include?(executable_tokens.first)
      return { safe: false, reason: "Statement contains non-read-only SQL." } if (executable_tokens & NON_READ_ONLY_KEYWORDS).any?
      return { safe: false, reason: "Statement contains user variables." } if executable_tokens.include?("@")
      if analyze_unsafe?
        return { safe: false, reason: "Statement contains SQL that is not safe for EXPLAIN ANALYZE." }
      end

      { safe: true, reason: "Read-only single-statement query; EXPLAIN ANALYZE will run with a short statement timeout." }
    end

    def analyze_unsafe?
      executable_tokens.each_cons(2).any? do |left, right|
        (ANALYZE_UNSAFE_FUNCTIONS.include?(left) && right == "(") || (left == "for" && right == "share")
      end || executable_tokens.include?("into")
    end

    # SQL validation only needs a small lexical view, not a full grammar. Text in
    # literals, quoted identifiers, and comments is deliberately omitted so it
    # cannot be mistaken for an executable keyword or function.
    def executable_tokens
      @executable_tokens ||= begin
        tokens = []
        index = 0

        while index < sql.length
          case sql[index]
          when "'", '"', "`"
            index = skip_quoted(index, sql[index])
          when "-"
            index = dash_comment_at?(index) ? skip_line_comment(index + 2) : append_token(tokens, index)
          when "#"
            index = skip_line_comment(index + 1)
          when "/"
            if sql[index, 3] == "/*!"
              tokens << "/*!"
              index = skip_block_comment(index + 3)
            else
              index = sql[index, 2] == "/*" ? skip_block_comment(index + 2) : append_token(tokens, index)
            end
          else
            if sql[index].match?(/[A-Za-z_]/)
              finish = index + 1
              finish += 1 while finish < sql.length && sql[finish].match?(/[A-Za-z0-9_$]/)
              tokens << sql[index...finish].downcase
              index = finish
            elsif ";(@?".include?(sql[index])
              tokens << sql[index]
              index += 1
            else
              index += 1
            end
          end
        end

        tokens.freeze
      end
    end

    def append_token(tokens, index)
      tokens << sql[index]
      index + 1
    end

    def skip_quoted(index, quote)
      index += 1
      while index < sql.length
        if sql[index] == "\\" && sql[index + 1] == quote
          # The quote is escaped in MySQL's default mode but terminates the
          # value under NO_BACKSLASH_ESCAPES, so no single tokenization is safe.
          @ambiguous_quote_escape = true
          index += 2
        elsif sql[index] == "\\" && index + 1 < sql.length
          index += 2
        elsif sql[index] == quote
          if sql[index + 1] == quote
            index += 2
          else
            return index + 1
          end
        else
          index += 1
        end
      end
      index
    end

    def skip_line_comment(index)
      index += 1 while index < sql.length && sql[index] != "\n"
      index
    end

    def dash_comment_at?(index)
      sql[index, 2] == "--" && (sql[index + 2].nil? || sql[index + 2].match?(/\s/))
    end

    def skip_block_comment(index)
      closing = sql.index("*/", index)
      closing ? closing + 2 : sql.length
    end
  end
end
