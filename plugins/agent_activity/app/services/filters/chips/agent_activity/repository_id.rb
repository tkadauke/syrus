module Filters
  module Chips
    module AgentActivity
      class RepositoryId < FkColumn
        filter_name "repository_id"
        label "Repository"
        column :repository_id
        operators :is

        def apply
          case op
          when :is then scope.where(repository_sql(value))
          else unsupported_op!
          end
        end

        private

        def repository_sql(repository_id)
          ActiveRecord::Base.sanitize_sql_array([
            "(
              agents.resumable_type = 'Run'
              AND EXISTS (
                SELECT 1
                FROM runs
                INNER JOIN jobs ON jobs.id = runs.job_id
                WHERE runs.id = agents.resumable_id
                  AND jobs.repository_id = ?
              )
            ) OR (
              agents.resumable_type = 'ChatSession'
              AND EXISTS (
                SELECT 1
                FROM chat_attachments
                WHERE chat_attachments.chat_session_id = agents.resumable_id
                  AND chat_attachments.attachable_type = 'Repository'
                  AND chat_attachments.attachable_id = ?
              )
            ) OR (
              agents.resumable_type = 'DesignDocs::DesignDocAgentRun'
              AND EXISTS (
                SELECT 1
                FROM design_doc_agent_runs
                INNER JOIN design_doc_repositories
                  ON design_doc_repositories.design_doc_id = design_doc_agent_runs.design_doc_id
                WHERE design_doc_agent_runs.id = agents.resumable_id
                  AND design_doc_repositories.repository_id = ?
              )
            )",
            repository_id,
            repository_id,
            repository_id
          ])
        end
      end
    end
  end
end
