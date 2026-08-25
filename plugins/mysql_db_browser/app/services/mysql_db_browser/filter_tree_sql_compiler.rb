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
      @client = client
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

    attr_reader :client, :fields

    def compile_node(node)
      case node
      when Filters::Ast::AndNode
        join(node.children, " AND ")
      when Filters::Ast::OrNode
        join(node.children, " OR ")
      when Filters::Ast::NotNode
        "NOT (#{compile_node(node.child)})"
      when Filters::Ast::Chip
        compile_chip(node)
      else
        raise ArgumentError, "unknown filter node: #{node.class}"
      end
    end

    def join(children, glue)
      return "1=1" if children.empty?

      children.map { |child| "(#{compile_node(child)})" }.join(glue)
    end

    def compile_chip(chip)
      field = fields[chip.field.to_s] or raise UnknownField, chip.field
      raise UnsupportedOperator, chip.op unless field[:operators].include?(chip.op.to_s)

      column = quote_identifier(field[:field])
      case field[:bucket]
      when "string" then compile_string(column, chip.op, chip.value)
      when "number" then compile_number(column, chip.op, chip.value)
      when "boolean" then compile_boolean(column, chip.op)
      when "date" then compile_date(column, chip.op, chip.value)
      when "enum" then compile_enum(column, chip.op, chip.value)
      else raise UnsupportedOperator, "unknown bucket #{field[:bucket]}"
      end
    end

    def compile_string(column, op, value)
      case op
      when "contains"            then like(column, "%%%s%%", value)
      when "does_not_contain"    then "NOT #{like(column, '%%%s%%', value)}"
      when "starts_with"         then like(column, "%s%%", value)
      when "does_not_start_with" then "NOT #{like(column, '%s%%', value)}"
      when "ends_with"           then like(column, "%%%s", value)
      when "does_not_end_with"   then "NOT #{like(column, '%%%s', value)}"
      when "equals"              then "#{column} = #{quote(value)}"
      when "not_equals"          then "(#{column} IS NULL OR #{column} <> #{quote(value)})"
      when "is_set"              then "(#{column} IS NOT NULL AND #{column} <> '')"
      when "is_unset"            then "(#{column} IS NULL OR #{column} = '')"
      end
    end

    def compile_number(column, op, value)
      case op
      when "equals"       then "#{column} = #{quote_number(value)}"
      when "not_equals"   then "(#{column} IS NULL OR #{column} <> #{quote_number(value)})"
      when "greater_than" then "#{column} > #{quote_number(value)}"
      when "less_than"    then "#{column} < #{quote_number(value)}"
      when "between"
        low, high = Array(value)
        "#{column} BETWEEN #{quote_number(low)} AND #{quote_number(high)}"
      when "is_set"   then "#{column} IS NOT NULL"
      when "is_unset" then "#{column} IS NULL"
      end
    end

    def compile_boolean(column, op)
      case op
      when "is_true"  then "#{column} = 1"
      when "is_false" then "#{column} = 0"
      end
    end

    def compile_date(column, op, value)
      case op
      when "before" then "#{column} < #{quote_time(value)}"
      when "after"  then "#{column} > #{quote_time(value)}"
      when "between"
        low, high = Array(value)
        "#{column} BETWEEN #{quote_time(low)} AND #{quote_time(high)}"
      when "within_last"
        "#{column} >= #{quote_time(duration_ago(value))}"
      when "more_than_ago"
        "#{column} < #{quote_time(duration_ago(value))}"
      when "is_set"   then "#{column} IS NOT NULL"
      when "is_unset" then "#{column} IS NULL"
      end
    end

    def compile_enum(column, op, value)
      case op
      when "is"          then "#{column} = #{quote(value)}"
      when "is_not"      then "(#{column} IS NULL OR #{column} <> #{quote(value)})"
      when "is_one_of"   then "#{column} IN (#{quote_list(value)})"
      when "is_none_of"  then "(#{column} IS NULL OR #{column} NOT IN (#{quote_list(value)}))"
      end
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
      "'#{client.escape(value.to_s)}'"
    end

    def quote_identifier(name)
      SqlIdentifier.quote(name)
    end
  end
end
