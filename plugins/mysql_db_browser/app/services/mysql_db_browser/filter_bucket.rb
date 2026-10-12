module MysqlDbBrowser
  module FilterBucket
    class UnknownBucket < ArgumentError; end

    class Base
      VALUELESS_OPERATORS = %w[is_set is_unset is_true is_false].freeze

      def self.bucket_name = const_get(:BUCKET_NAME)
      def self.operators = const_get(:OPERATORS).keys.freeze
      def self.matches?(_column) = false
      def self.value_required?(op) = VALUELESS_OPERATORS.exclude?(op.to_s)

      def initialize(context:, column:)
        @context = context
        @column = column
      end

      def compile(op, value)
        handler = self.class.const_get(:OPERATORS).fetch(op.to_s)
        __send__(handler, value)
      end

      private

      attr_reader :context, :column

      delegate :duration_ago, :like, :quote, :quote_list, :quote_number, :quote_time, to: :context
    end

    class StringBucket < Base
      BUCKET_NAME = "string"
      OPERATORS = {
        "contains" => :contains,
        "does_not_contain" => :does_not_contain,
        "starts_with" => :starts_with,
        "does_not_start_with" => :does_not_start_with,
        "ends_with" => :ends_with,
        "does_not_end_with" => :does_not_end_with,
        "equals" => :equals,
        "not_equals" => :not_equals,
        "is_set" => :is_set,
        "is_unset" => :is_unset
      }.freeze

      def self.matches?(_column) = true

      private

      def contains(value) = like(column, "%%%s%%", value)
      def does_not_contain(value) = "NOT #{like(column, '%%%s%%', value)}"
      def starts_with(value) = like(column, "%s%%", value)
      def does_not_start_with(value) = "NOT #{like(column, '%s%%', value)}"
      def ends_with(value) = like(column, "%%%s", value)
      def does_not_end_with(value) = "NOT #{like(column, '%%%s', value)}"
      def equals(value) = "#{column} = #{quote(value)}"
      def not_equals(value) = "(#{column} IS NULL OR #{column} <> #{quote(value)})"
      def is_set(_value) = "(#{column} IS NOT NULL AND #{column} <> '')"
      def is_unset(_value) = "(#{column} IS NULL OR #{column} = '')"
    end

    class NumberBucket < Base
      BUCKET_NAME = "number"
      MYSQL_TYPES = %w[tinyint smallint mediumint int integer bigint decimal numeric float double real].freeze
      OPERATORS = {
        "equals" => :equals,
        "not_equals" => :not_equals,
        "greater_than" => :greater_than,
        "less_than" => :less_than,
        "between" => :between,
        "is_set" => :is_set,
        "is_unset" => :is_unset
      }.freeze

      def self.matches?(column) = MYSQL_TYPES.include?(column[:data_type].to_s.downcase)

      private

      def equals(value) = "#{column} = #{quote_number(value)}"
      def not_equals(value) = "(#{column} IS NULL OR #{column} <> #{quote_number(value)})"
      def greater_than(value) = "#{column} > #{quote_number(value)}"
      def less_than(value) = "#{column} < #{quote_number(value)}"

      def between(value)
        low, high = Array(value)
        "#{column} BETWEEN #{quote_number(low)} AND #{quote_number(high)}"
      end

      def is_set(_value) = "#{column} IS NOT NULL"
      def is_unset(_value) = "#{column} IS NULL"
    end

    class BooleanBucket < Base
      BUCKET_NAME = "boolean"
      OPERATORS = {
        "is_true" => :is_true,
        "is_false" => :is_false
      }.freeze

      def self.matches?(column) = column[:column_type].to_s.downcase == "tinyint(1)"

      private

      def is_true(_value) = "#{column} = 1"
      def is_false(_value) = "#{column} = 0"
    end

    class DateBucket < Base
      BUCKET_NAME = "date"
      MYSQL_TYPES = %w[date datetime timestamp time year].freeze
      OPERATORS = {
        "before" => :before,
        "after" => :after,
        "between" => :between,
        "within_last" => :within_last,
        "more_than_ago" => :more_than_ago,
        "is_set" => :is_set,
        "is_unset" => :is_unset
      }.freeze

      def self.matches?(column) = MYSQL_TYPES.include?(column[:data_type].to_s.downcase)

      private

      def before(value) = "#{column} < #{quote_time(value)}"
      def after(value) = "#{column} > #{quote_time(value)}"

      def between(value)
        low, high = Array(value)
        "#{column} BETWEEN #{quote_time(low)} AND #{quote_time(high)}"
      end

      def within_last(value) = "#{column} >= #{quote_time(duration_ago(value))}"
      def more_than_ago(value) = "#{column} < #{quote_time(duration_ago(value))}"
      def is_set(_value) = "#{column} IS NOT NULL"
      def is_unset(_value) = "#{column} IS NULL"
    end

    class EnumBucket < Base
      BUCKET_NAME = "enum"
      OPERATORS = {
        "is" => :is,
        "is_not" => :is_not,
        "is_one_of" => :is_one_of,
        "is_none_of" => :is_none_of
      }.freeze

      def self.matches?(column) = column[:data_type].to_s.downcase == "enum"

      private

      def is(value) = "#{column} = #{quote(value)}"
      def is_not(value) = "(#{column} IS NULL OR #{column} <> #{quote(value)})"
      def is_one_of(value) = "#{column} IN (#{quote_list(value)})"
      def is_none_of(value) = "(#{column} IS NULL OR #{column} NOT IN (#{quote_list(value)}))"
    end

    BUCKETS = [
      BooleanBucket,
      EnumBucket,
      NumberBucket,
      DateBucket,
      StringBucket
    ].freeze
    BY_NAME = BUCKETS.index_by(&:bucket_name).freeze

    def self.for_name(name)
      BY_NAME.fetch(name.to_s) { raise UnknownBucket, "unknown bucket #{name}" }
    end

    def self.for_column(column)
      BUCKETS.find { |bucket| bucket.matches?(column) }
    end
  end
end
