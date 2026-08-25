module MysqlDbBrowser
  # Derives a FilterBar-compatible filterSchema (see
  # app/frontend/components/filterBar/types.ts's FilterSchemaField) from a
  # table's introspected columns (MysqlDbBrowser::SchemaInspector#table
  # column payloads). This is the "column -> field, MySQL type -> bucket,
  # bucket -> operators" glue the issue calls for - no new filter-chip UI,
  # just data FilterBar already knows how to render.
  class FilterSchemaBuilder
    STRING_OPERATORS = %w[contains does_not_contain starts_with does_not_start_with ends_with does_not_end_with equals not_equals is_set is_unset].freeze
    NUMBER_OPERATORS = %w[equals not_equals greater_than less_than between is_set is_unset].freeze
    BOOLEAN_OPERATORS = %w[is_true is_false].freeze
    DATE_OPERATORS = %w[before after between within_last more_than_ago is_set is_unset].freeze
    ENUM_OPERATORS = %w[is is_not is_one_of is_none_of].freeze

    def self.build(columns)
      columns.map { |column| field_for(column) }
    end

    def self.field_for(column)
      bucket = bucket_for(column)
      field = {
        field: column[:name],
        label: column[:name].to_s.humanize,
        bucket: bucket,
        operators: operators_for(bucket)
      }
      field[:values] = enum_values(column[:column_type]) if bucket == "enum"
      field
    end
    private_class_method :field_for

    def self.bucket_for(column)
      data_type = column[:data_type].to_s.downcase
      column_type = column[:column_type].to_s.downcase

      return "boolean" if column_type == "tinyint(1)"
      return "enum" if data_type == "enum"
      return "number" if %w[tinyint smallint mediumint int integer bigint decimal numeric float double real].include?(data_type)
      return "date" if %w[date datetime timestamp time year].include?(data_type)

      "string"
    end
    private_class_method :bucket_for

    def self.operators_for(bucket)
      case bucket
      when "number" then NUMBER_OPERATORS
      when "boolean" then BOOLEAN_OPERATORS
      when "date" then DATE_OPERATORS
      when "enum" then ENUM_OPERATORS
      else STRING_OPERATORS
      end
    end
    private_class_method :operators_for

    # MySQL renders an enum's COLUMN_TYPE as `enum('a','b','c')`. Values can
    # contain escaped quotes (`''` or `\'`); this handles both.
    def self.enum_values(column_type)
      column_type.to_s.scan(/'((?:[^'\\]|\\.|'')*)'/).flatten.map { |value| value.gsub("''", "'").gsub("\\'", "'") }
    end
    private_class_method :enum_values
  end
end
