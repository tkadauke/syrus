module Filters
  module Chips
    # Base for chips that filter on a datetime column. Value shapes:
    #
    #   before          { "value": "2026-05-01T00:00:00Z" }
    #   after           { "value": "2026-05-01T00:00:00Z" }
    #   between         { "value": ["2026-05-01", "2026-05-31"] }
    #   within_last     { "value": { "n": 7, "unit": "days" } }
    #   more_than_ago   { "value": { "n": 7, "unit": "days" } }
    #   is_set / is_unset (no value)
    #
    # within_last/more_than_ago units: minutes / hours / days / weeks /
    # months. Anything else raises.
    class DateColumn < Base
      bucket :date
      operators :before, :after, :between, :within_last, :more_than_ago, :is_set, :is_unset
      date_precision :datetime

      UNITS = {
        "minutes" => 1.minute,
        "hours"   => 1.hour,
        "days"    => 1.day,
        "weeks"   => 1.week,
        "months"  => 1.month
      }.freeze

      class << self
        def column(name = nil)
          @column = name.to_sym if name
          @column or raise NotImplementedError, "#{self.name} must declare `column :name`"
        end
      end

      def apply
        col = self.class.column
        case op
        when :before then scope.where(col => ..to_time(value))
        when :after  then scope.where(col => to_time(value)..)
        when :between
          range = Array(value)
          scope.where(col => to_time(range.first)..to_time(range.last))
        when :within_last
          cutoff = duration_for(value).ago
          scope.where(col => cutoff..)
        when :more_than_ago
          cutoff = duration_for(value).ago
          scope.where(col => ..cutoff)
        when :is_set   then scope.where.not(col => nil)
        when :is_unset then scope.where(col => nil)
        else unsupported_op!
        end
      end

      private

      def to_time(value)
        case value
        when Time, DateTime, ActiveSupport::TimeWithZone then value
        when Date then value.in_time_zone
        else Time.zone.parse(value.to_s)
        end
      end

      def duration_for(value)
        spec = value.is_a?(Hash) ? value : {}
        n = Integer(spec["n"] || spec[:n] || 0)
        unit_key = (spec["unit"] || spec[:unit]).to_s
        per = UNITS[unit_key] or raise ArgumentError, "unknown duration unit: #{unit_key.inspect}"
        per * n
      end
    end
  end
end
