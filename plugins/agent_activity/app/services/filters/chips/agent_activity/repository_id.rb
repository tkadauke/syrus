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
            "agents.resumable_type = 'Run'
             AND EXISTS (
               SELECT 1
               FROM runs
               INNER JOIN jobs ON jobs.id = runs.job_id
               WHERE runs.id = agents.resumable_id
                 AND jobs.repository_id = ?
             )",
            repository_id
          ])
        end
      end
    end
  end
end
