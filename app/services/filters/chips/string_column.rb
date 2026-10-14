module Filters
  module Chips
    # Base for chips that filter on a free-text column. Subclasses
    # declare a column. Regex operators are gated server-side via
    # `regex_supported` so the chip's editor can hide them when the
    # DB doesn't support REGEXP (SQLite doesn't have a builtin; MySQL
    # does). Today's default is regex disabled until we have a
    # cross-DB path.
    class StringColumn < Base
      bucket :string
      operators :contains, :does_not_contain,
                :starts_with, :does_not_start_with,
                :ends_with, :does_not_end_with,
                :equals, :not_equals,
                :is_set, :is_unset

      class << self
        def column(name = nil)
          @column = name.to_sym if name
          @column or raise NotImplementedError, "#{self.name} must declare `column :name`"
        end
      end

      def apply
        col = self.class.column
        case op
        when :contains              then like(col, "%#{escape_like(value)}%")
        when :does_not_contain      then not_like(col, "%#{escape_like(value)}%")
        when :starts_with           then like(col, "#{escape_like(value)}%")
        when :does_not_start_with   then not_like(col, "#{escape_like(value)}%")
        when :ends_with             then like(col, "%#{escape_like(value)}")
        when :does_not_end_with     then not_like(col, "%#{escape_like(value)}")
        when :equals                then scope.where(col => value)
        when :not_equals            then exclude_matches(scope.where(col => value))
        when :is_set                then scope.where.not(col => [ nil, "" ])
        when :is_unset              then scope.where(col => [ nil, "" ])
        else unsupported_op!
        end
      end

      private

      def like(col, pattern)
        scope.where("#{quoted_column(col)} LIKE ? ESCAPE #{like_escape_sql}", pattern)
      end

      def not_like(col, pattern)
        exclude_matches(like(col, pattern))
      end

      def quoted_column(col)
        "#{scope.connection.quote_table_name(scope.table_name)}.#{scope.connection.quote_column_name(col)}"
      end
    end
  end
end
