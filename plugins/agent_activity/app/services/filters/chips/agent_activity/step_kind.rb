module Filters
  module Chips
    module AgentActivity
      # "Role" in the UI: the Step#kind of the agentic step this session ran
      # as. Named after the DB column (step_kind, joined from `steps`) rather
      # than the derived AgentRole value, so the chip's `value` matches
      # exactly what SessionsQuery groups by.
      class StepKind < Base
        filter_name "step_kind"
        label "Role"
        bucket :enum
        operators :is_one_of
        values(*Step::AGENTIC_KINDS.map { |kind| { "value" => kind, "label" => Step::Kind.label_for(kind) } })

        def apply
          case op
          when :is_one_of
            scope.where(workflow_role_sql(Array(value)))
          else unsupported_op!
          end
        end

        private

        def workflow_role_sql(kinds)
          ActiveRecord::Base.sanitize_sql_array([
            "agents.resumable_type = 'Run'
             AND EXISTS (
               SELECT 1
               FROM runs
               INNER JOIN steps ON steps.id = runs.step_id
               WHERE runs.id = agents.resumable_id
                 AND steps.kind IN (?)
             )",
            kinds
          ])
        end
      end
    end
  end
end
