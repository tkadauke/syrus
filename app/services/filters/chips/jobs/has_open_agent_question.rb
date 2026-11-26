module Filters
  module Chips
    module Jobs
      class HasOpenAgentQuestion < Base
        filter_name "has_open_agent_question"
        label "Waiting for your answer"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          matching = AgentQuestion.active.where.not(run_id: nil).joins(:run).select("runs.job_id")
          case op
          when :is_true then scope.where(id: matching)
          when :is_false then scope.where.not(id: matching)
          else unsupported_op!
          end
        end
      end
    end
  end
end
