module Filters
  module Chips
    module SpendingReport
      class CreatedAt < DateColumn
        filter_name "created_at"
        label "Datetime"
        column :created_at
        operators :before, :after, :between, :within_last, :more_than_ago
        date_precision :date

        def apply
          case op
          when :before then scope.where(created_at: ..end_of_day(value))
          when :after then scope.where(created_at: start_of_day(value)..)
          when :between
            range = Array(value)
            scope.where(created_at: start_of_day(range.first)..end_of_day(range.last))
          else
            super
          end
        end

        private

        def start_of_day(raw)
          parse_time(raw)&.beginning_of_day
        end

        def end_of_day(raw)
          parse_time(raw)&.end_of_day
        end

        def parse_time(raw)
          return if raw.blank?

          Time.zone.parse(raw.to_s)
        end
      end
    end
  end
end
