module Filters
  module Chips
    module AgentActivity
      class AgentProvider < EnumColumn
        filter_name "agent_provider"
        label "Agent"
        column :agent_provider

        def self.values
          User.agent_providers
        end

        def apply
          case op
          when :is then scope.where(provider_sql(value))
          when :is_one_of then scope.where(provider_sql(Array(value)))
          else super
          end
        end

        private

        def provider_sql(providers)
          providers = Array(providers)
          ActiveRecord::Base.sanitize_sql_array([
            "(
              agents.resumable_type = 'Run'
              AND EXISTS (
                SELECT 1
                FROM runs
                WHERE runs.id = agents.resumable_id
                  AND runs.agent_provider IN (?)
              )
            ) OR (
              agents.resumable_type = 'ChatSession'
              AND EXISTS (
                SELECT 1
                FROM chat_sessions
                WHERE chat_sessions.id = agents.resumable_id
                  AND chat_sessions.chat_provider IN (?)
              )
            ) OR (
              agents.resumable_type = 'DesignDocs::DesignDocAgentRun'
              AND EXISTS (
                SELECT 1
                FROM design_doc_agent_runs
                WHERE design_doc_agent_runs.id = agents.resumable_id
                  AND design_doc_agent_runs.agent_provider IN (?)
              )
            )",
            providers,
            providers,
            providers
          ])
        end
      end
    end
  end
end
