module MysqlDbBrowser
  # Compiles a Metabase-notebook-style query builder spec - a base table, a
  # raw column list or an aggregate/group-by summary, one optional join
  # (surfaced from SchemaInspector's foreign_keys), a sort, and a limit -
  # into a single SELECT statement for QueryExecutor#execute_select. The
  # WHERE clause itself is not this class's concern: the controller compiles
  # it separately via FilterTreeSqlCompiler, against this class's
  # #filter_schema, and passes the resulting fragment into #sql.
  #
  # Every table/column/aggregation-function name in the spec is checked
  # against the real, introspected column list for its table before being
  # interpolated - an out-of-band table or column name is rejected with
  # InvalidSpec before any SQL is built. On top of that, every identifier is
  # still quoted through SqlIdentifier so nothing can break out of
  # identifier position.
  #
  # Column references (in `columns`, `aggregations[].column`, `group_by`,
  # `join.from_column`/`join.to_column`, and `sort.column`) are always
  # "table.column" qualified strings - the frontend always knows which
  # table a picker belongs to, so requiring qualification everywhere (rather
  # than only when a join is present) keeps this class's column resolution
  # to one code path.
  class QueryBuilderCompiler
    AGGREGATE_FUNCTIONS = %w[count sum avg min max].freeze
    JOIN_TYPES = %w[inner left].freeze
    ALIAS_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 500

    class InvalidSpec < ArgumentError; end

    def initialize(spec:, base_table:, base_columns:, join_table: nil, join_columns: [])
      @spec = spec || {}
      @base_table = base_table.to_s
      @base_column_defs = Array(base_columns)
      @join_spec = @spec[:join]
      @join_table = @join_spec ? join_table.to_s : nil
      @join_column_defs = @join_spec ? Array(join_columns) : []
      @tables = { @base_table => @base_column_defs.map { |column| column[:name].to_s } }
      @tables[@join_table] = @join_column_defs.map { |column| column[:name].to_s } if joined?

      validate!
    end

    def joined?
      @join_spec.present?
    end

    def aggregate_mode?
      Array(@spec[:aggregations]).any?
    end

    def filter_schema
      fields = FilterSchemaBuilder.build(@base_column_defs, table_prefix: @base_table)
      fields += FilterSchemaBuilder.build(@join_column_defs, table_prefix: @join_table) if joined?
      fields
    end

    def limit
      raw = @spec[:limit].presence || DEFAULT_LIMIT
      [ [ raw.to_i, 1 ].max, MAX_LIMIT ].min
    end

    def sql(where_clause: nil)
      parts = [ "SELECT #{select_list.join(', ')}", "FROM #{quote_table(@base_table)}" ]
      parts << join_clause if joined?
      parts << "WHERE #{where_clause}" if where_clause.present?
      parts << "GROUP BY #{group_by_list.join(', ')}" if aggregate_mode? && group_by_list.any?
      parts << "ORDER BY #{order_by_clause}" if order_by_clause
      parts << "LIMIT #{limit}"
      parts.join(" ")
    end

    private

    def select_list
      aggregate_mode? ? (group_by_list + aggregation_expressions) : plain_select_list
    end

    def plain_select_list
      requested = Array(@spec[:columns])
      return default_star_columns if requested.empty?

      requested.map { |ref| quote_column(resolve_column!(ref)) }
    end

    def default_star_columns
      stars = [ "#{quote_table(@base_table)}.*" ]
      stars << "#{quote_table(@join_table)}.*" if joined?
      stars
    end

    def group_by_list
      @group_by_list ||= Array(@spec[:group_by]).map { |ref| quote_column(resolve_column!(ref)) }
    end

    def aggregation_expressions
      Array(@spec[:aggregations]).map { |aggregation| aggregation_expression(aggregation) }
    end

    def aggregation_expression(aggregation)
      function = aggregation[:function].to_s
      raise InvalidSpec, "unknown aggregation function: #{function.inspect}" unless AGGREGATE_FUNCTIONS.include?(function)

      column_ref = aggregation[:column].to_s
      expression =
        if column_ref == "*"
          raise InvalidSpec, "#{function}(*) is only supported for count" unless function == "count"

          "COUNT(*)"
        else
          "#{function.upcase}(#{quote_column(resolve_column!(column_ref))})"
        end

      "#{expression} AS #{quote_alias(alias_for(aggregation, function, column_ref))}"
    end

    def alias_for(aggregation, function, column_ref)
      requested = aggregation[:alias]
      return requested if requested.present?
      return "row_count" if column_ref == "*"

      _table, column = column_ref.to_s.split(".", 2)
      "#{function}_#{column}"
    end

    def join_clause
      keyword = @join_spec[:type].to_s.presence || "left"
      raise InvalidSpec, "unknown join type: #{keyword.inspect}" unless JOIN_TYPES.include?(keyword)

      from_column = quote_column(resolve_column!(@join_spec[:from_column]))
      to_column = quote_column(resolve_column!(@join_spec[:to_column]))
      "#{keyword.upcase} JOIN #{quote_table(@join_table)} ON #{from_column} = #{to_column}"
    end

    def order_by_clause
      sort = @spec[:sort]
      return nil if sort.blank? || sort[:column].blank?

      direction = sort[:direction].to_s.downcase == "desc" ? "DESC" : "ASC"
      "#{sortable_column(sort[:column].to_s)} #{direction}"
    end

    def sortable_column(requested)
      if aggregate_mode?
        aliases = Array(@spec[:aggregations]).map { |aggregation| alias_for(aggregation, aggregation[:function].to_s, aggregation[:column].to_s) }
        return quote_alias(requested) if aliases.include?(requested)
        return quote_column(resolve_column!(requested)) if Array(@spec[:group_by]).map(&:to_s).include?(requested)

        raise InvalidSpec, "sort column #{requested.inspect} is not a group-by column or aggregation alias"
      else
        selected = Array(@spec[:columns]).map(&:to_s)
        return quote_column(resolve_column!(requested)) if selected.empty? || selected.include?(requested)

        raise InvalidSpec, "sort column #{requested.inspect} was not selected"
      end
    end

    def resolve_column!(ref)
      table, column = ref.to_s.split(".", 2)
      raise InvalidSpec, "column #{ref.inspect} must be qualified as table.column" if column.blank?

      names = @tables[table]
      raise InvalidSpec, "unknown table #{table.inspect} in column reference #{ref.inspect}" unless names
      raise InvalidSpec, "unknown column #{column.inspect} on #{table}" unless names.include?(column)

      [ table, column ]
    end

    def quote_column((table, column))
      "#{quote_table(table)}.#{SqlIdentifier.quote(column)}"
    end

    def quote_table(name)
      SqlIdentifier.quote(name)
    end

    def quote_alias(name)
      raise InvalidSpec, "alias #{name.inspect} must be a simple identifier" unless name.to_s.match?(ALIAS_PATTERN)

      "`#{name}`"
    end

    def validate!
      raise InvalidSpec, "table is required" if @base_table.blank?
      raise InvalidSpec, "join.table is required" if joined? && @join_table.blank?
      raise InvalidSpec, "group_by requires at least one aggregation" if !aggregate_mode? && Array(@spec[:group_by]).any?

      # Force eager evaluation of every column/alias/join reference so an
      # invalid spec raises here, not partway through building #sql.
      select_list
      join_clause if joined?
      order_by_clause
    end
  end
end
