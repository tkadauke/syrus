module Filters
  module Chips
    module SpawnedProcesses
      class UserId < Base
        filter_name "user_id"
        label "User"
        bucket :fk
        operators :is, :is_not

        def apply
          case op
          when :is
            scope.where(id: matching_process_ids)
          when :is_not
            scope.where.not(id: matching_process_ids)
          else
            unsupported_op!
          end
        end

        private

        def matching_process_ids
          id = Integer(value, exception: false)
          return SpawnedProcess.none.select(:id) unless id

          SpawnedProcess
            .joins(user_owner_joins)
            .where(user_owner_condition, user_id: id)
            .select(:id)
        end

        def user_owner_condition
          [
            "COALESCE(spawned_process_workflow_jobs.owner_user_id, workflows.user_id) = :user_id",
            "chat_sessions.user_id = :user_id",
            "COALESCE(spawned_process_preview_jobs.owner_user_id, spawned_process_preview_jobs.user_id) = :user_id"
          ].join(" OR ")
        end

        def user_owner_joins
          <<~SQL.squish
            LEFT OUTER JOIN workflows
              ON workflows.id = spawned_processes.workflow_id
            LEFT OUTER JOIN jobs spawned_process_workflow_jobs
              ON spawned_process_workflow_jobs.id = workflows.job_id
            LEFT OUTER JOIN chat_sessions
              ON chat_sessions.id = spawned_processes.chat_session_id
            LEFT OUTER JOIN jobs spawned_process_preview_jobs
              ON spawned_processes.kind = 'preview'
             AND spawned_process_preview_jobs.id = #{preview_job_id_sql}
          SQL
        end

        def preview_job_id_sql
          if ActiveRecord::Base.connection.adapter_name.match?(/mysql/i)
            "CAST(JSON_UNQUOTE(JSON_EXTRACT(spawned_processes.resource_attribution, '$.job_id')) AS UNSIGNED)"
          else
            "CAST(json_extract(spawned_processes.resource_attribution, '$.job_id') AS INTEGER)"
          end
        end
      end
    end
  end
end
