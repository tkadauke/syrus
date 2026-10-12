module MysqlDbBrowser
  # Derives a FilterBar-compatible filterSchema (see
  # app/frontend/components/filterBar/types.ts's FilterSchemaField) from a
  # table's introspected columns (MysqlDbBrowser::SchemaInspector#table
  # column payloads). This is the "column -> field, MySQL type -> bucket,
  # bucket -> operators" glue the issue calls for - no new filter-chip UI,
  # just data FilterBar already knows how to render.
  #
  # table_prefix qualifies the field name as "table.column" (and the label
  # as "Table: Column") - used by the query builder's filter step, where a
  # join can put two tables' columns in the same filterSchema and an
  # unqualified field name would be ambiguous.
  class FilterSchemaBuilder
    def self.build(columns, table_prefix: nil)
      columns.map { |column| field_for(column, table_prefix) }
    end

    def self.field_for(column, table_prefix = nil)
      bucket = FilterBucket.for_column(column)
      name = column[:name].to_s
      field = {
        field: table_prefix ? "#{table_prefix}.#{name}" : name,
        label: table_prefix ? "#{table_prefix.to_s.humanize}: #{name.humanize}" : name.humanize,
        bucket: bucket.bucket_name,
        operators: bucket.operators
      }
      field[:values] = enum_values(column[:column_type]) if bucket == FilterBucket::EnumBucket
      field
    end
    private_class_method :field_for

    # MySQL renders an enum's COLUMN_TYPE as `enum('a','b','c')`. Values can
    # contain escaped quotes (`''` or `\'`); this handles both.
    def self.enum_values(column_type)
      column_type.to_s.scan(/'((?:[^'\\]|\\.|'')*)'/).flatten.map { |value| value.gsub("''", "'").gsub("\\'", "'") }
    end
    private_class_method :enum_values
  end
end
