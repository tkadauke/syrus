module Filters
  module Chips
    module AgentActivity
      class Status < Base
        filter_name "status"
        label "Status"
        bucket :enum
        operators :is, :is_one_of
        values "running", "succeeded", "failed", "timed_out", "silent_timed_out", "aliveness_failed", "operator_killed", "stopped", "orphaned"

        def apply
          values = Array(value)
          predicates = values.map { |status| predicate_for(status.to_s) }
          return scope.none if predicates.empty?

          scope.where(predicates.reduce { |left, right| "(#{left}) OR (#{right})" })
        end

        private

        def predicate_for(status)
          handlers.fetch(status, method(:latest_outcome_predicate)).call(status)
        end

        def handlers
          {
            "running" => method(:running_predicate),
            "failed" => method(:failed_predicate)
          }
        end

        def running_predicate(_status)
          ::AgentActivity::SessionsQuery.running_process_exists_sql
        end

        def failed_predicate(_status)
          "#{::AgentActivity::SessionsQuery.latest_process_outcome_sql} = 'failed'"
        end

        def latest_outcome_predicate(status)
          quoted = ActiveRecord::Base.connection.quote(status)
          "#{::AgentActivity::SessionsQuery.latest_process_outcome_sql} = #{quoted}"
        end
      end
    end
  end
end
