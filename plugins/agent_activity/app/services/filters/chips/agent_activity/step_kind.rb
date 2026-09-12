module Filters
  module Chips
    module AgentActivity
      # "Role" in the UI: the Step#kind of the agentic step this session ran
      # as for workflow-backed agents, ChatSession#mode for chat-backed agents,
      # and "design_doc" for design-doc-backed agents.
      class StepKind < Base
        filter_name "step_kind"
        label "Role"
        bucket :enum
        operators :is_one_of
        values(
          *Step::AGENTIC_KINDS.map { |kind| { "value" => kind, "label" => Step::Kind.label_for(kind) } },
          *ChatSession::MODES.map { |mode| { "value" => mode, "label" => mode.humanize } },
          { "value" => "design_doc", "label" => "Design Doc" }
        )

        def apply
          case op
          when :is_one_of
            scope.where(role_sql(Array(value).map(&:to_s)))
          else unsupported_op!
          end
        end

        private

        def role_sql(values)
          workflow_kinds = values & Step::AGENTIC_KINDS
          chat_modes = values & ChatSession::MODES
          predicates = []
          binds = []

          if workflow_kinds.any?
            predicates << "(
              agents.resumable_type = 'Run'
              AND EXISTS (
                SELECT 1
                FROM runs
                INNER JOIN steps ON steps.id = runs.step_id
                WHERE runs.id = agents.resumable_id
                  AND steps.kind IN (?)
              )
            )"
            binds << workflow_kinds
          end

          if chat_modes.any?
            predicates << "(
              agents.resumable_type = 'ChatSession'
              AND EXISTS (
                SELECT 1
                FROM chat_sessions
                WHERE chat_sessions.id = agents.resumable_id
                  AND chat_sessions.mode IN (?)
              )
            )"
            binds << chat_modes
          end

          predicates << "agents.resumable_type = 'DesignDocs::DesignDocAgentRun'" if values.include?("design_doc")
          return "1=0" if predicates.empty?

          ActiveRecord::Base.sanitize_sql_array([
            predicates.map { |predicate| "(#{predicate})" }.join(" OR "),
            *binds
          ])
        end
      end
    end
  end
end
