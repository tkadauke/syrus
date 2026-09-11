module Filters
  module Chips
    module AgentActivity
      class Window < DateColumn
        filter_name "window"
        label "Time window"
        column :started_at
        operators :within_last, :between

        def apply
          case op
          when :within_last
            scope.where("#{::AgentActivity::SessionsQuery.latest_process_started_sql} >= ?", duration_for(value).ago)
          when :between
            range = Array(value)
            scope.where("#{::AgentActivity::SessionsQuery.latest_process_started_sql} BETWEEN ? AND ?", to_time(range.first), to_time(range.last))
          else unsupported_op!
          end
        end
      end
    end
  end
end
