module MysqlDbBrowser
  # Compiles a FilterBar FilterTree (the same and/or/not/chip JSON shape
  # FilterBar posts everywhere else in Syrus - see Filters::Ast) into a raw
  # SQL WHERE fragment for an arbitrary external MySQL table, using the
  # filterSchema built by FilterSchemaBuilder to resolve each chip's field
  # to a real column + bucket. Values are escaped through the same
  # Mysql2::Client used to run the query, never interpolated raw.
  class FilterTreeSqlCompiler
    class UnknownField < ArgumentError; end
    class UnsupportedOperator < ArgumentError; end

    DURATION_SECONDS = {
      "minutes" => 60,
      "hours" => 3_600,
      "days" => 86_400,
      "weeks" => 604_800,
      "months" => 2_592_000
    }.freeze

    def initialize(client:, filter_schema:)
      @context = CompilationContext.new(client)
      @fields = filter_schema.index_by { |field| field[:field].to_s }
    end

    # tree is the JSON-friendly Hash a FilterBar chip-bar submits (already
    # decoded from the `q` param via Filters::QueryParam.decode). Returns
    # nil when the tree has no chips, so callers can skip the WHERE clause
    # entirely instead of emitting a vacuous "WHERE 1=1".
    def compile(tree)
      ast = Filters::Ast.parse(tree)
      return nil if ast.is_a?(Filters::Ast::AndNode) && ast.children.empty?

      compile_node(ast)
    end

    private

    attr_reader :context, :fields

    def compile_node(node)
      case node
      when Filters::Ast::AndNode
        join(node.children, " AND ")
      when Filters::Ast::OrNode
        join(node.children, " OR ")
      when Filters::Ast::NotNode
        clause = compile_node(node.child)
        clause.present? ? "NOT (#{clause})" : nil
      when Filters::Ast::Chip
        compile_chip(node)
      else
        raise ArgumentError, "unknown filter node: #{node.class}"
      end
    end

    def join(children, glue)
      compiled = children.filter_map { |child| compile_node(child).presence }
      return nil if compiled.empty?

      compiled.map { |clause| "(#{clause})" }.join(glue)
    end

    def compile_chip(chip)
      field = fields[chip.field.to_s] or raise UnknownField, chip.field
      raise UnsupportedOperator, chip.op unless field[:operators].include?(chip.op.to_s)
      bucket = bucket_for(field[:bucket])
      return nil if bucket.value_required?(chip.op) && blank_filter_value?(chip.value)

      column = quote_identifier(field[:field])
      bucket.new(context: context, column: column).compile(chip.op, chip.value)
    end

    def bucket_for(name)
      FilterBucket.for_name(name)
    rescue FilterBucket::UnknownBucket => e
      raise UnsupportedOperator, e.message
    end

    def blank_filter_value?(value)
      case value
      when Array
        value.all? { |item| blank_filter_value?(item) }
      when Hash
        value.values.all? { |item| blank_filter_value?(item) }
      else
        value.blank?
      end
    end

    def quote_identifier(name)
      SqlIdentifier.quote(name)
    end

    class CompilationContext
      def initialize(client)
        @client = client
      end

      def like(column, template, value)
        escaped = value.to_s.gsub(/[%_\\]/) { |char| "\\#{char}" }
        "#{column} LIKE #{quote(format(template, escaped))}"
      end

      def duration_ago(value)
        spec = value.is_a?(Hash) ? value : {}
        n = Integer(spec["n"] || spec[:n] || 0)
        unit = (spec["unit"] || spec[:unit]).to_s
        seconds = DURATION_SECONDS[unit] or raise ArgumentError, "unknown duration unit: #{unit.inspect}"
        Time.current - (seconds * n)
      end

      def quote_number(value)
        Float(value)
      rescue TypeError, ArgumentError
        "NULL"
      end

      def quote_time(value)
        time = value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone) ? value : Time.zone.parse(value.to_s)
        quote(time.strftime("%Y-%m-%d %H:%M:%S"))
      end

      def quote_list(value)
        Array(value).map { |item| quote(item) }.join(", ")
      end

      def quote(value)
        "'#{@client.escape(value.to_s)}'"
      end
    end
  end
end
