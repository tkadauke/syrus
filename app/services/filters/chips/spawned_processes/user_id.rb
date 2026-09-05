module Filters
  module Chips
    module SpawnedProcesses
      class UserId < Base
        filter_name "user_id"
        label "User"
        bucket :fk
        operators :is, :is_not, :is_set, :is_unset

        def apply
          case op
          when :is
            id = Integer(value, exception: false)
            id ? owned_by_user(id) : scope.none
          when :is_not
            id = Integer(value, exception: false)
            id ? scope.where.not(id: owned_by_user(id).select(:id)) : scope
          when :is_set
            scope.where(id: owned_by_any_user.select(:id))
          when :is_unset
            scope.where.not(id: owned_by_any_user.select(:id))
          else
            unsupported_op!
          end
        end

        private

        def owned_by_user(user_id)
          with_owner_joins.where(owner_user_condition(user_id))
        end

        def owned_by_any_user
          with_owner_joins.where(any_owner_user_condition)
        end

        def with_owner_joins
          scope.left_outer_joins(:workflow, :chat_session)
        end

        def owner_user_condition(user_id)
          sql = [
            "workflows.user_id = :user_id",
            "chat_sessions.user_id = :user_id",
            "#{json_extract('job_id')} IN (SELECT jobs.id FROM jobs WHERE jobs.user_id = :user_id)",
            "#{json_extract('repository_id')} IN (SELECT repositories.id FROM repositories WHERE repositories.user_id = :user_id)",
            "#{json_extract('preview_environment_id')} IN (#{preview_environment_owner_sql})"
          ].join(" OR ")
          [ sql, { user_id: user_id } ]
        end

        def any_owner_user_condition
          sql = [
            "workflows.user_id IS NOT NULL",
            "chat_sessions.user_id IS NOT NULL",
            "#{json_extract('job_id')} IN (SELECT jobs.id FROM jobs WHERE jobs.user_id IS NOT NULL)",
            "#{json_extract('repository_id')} IN (SELECT repositories.id FROM repositories WHERE repositories.user_id IS NOT NULL)",
            "#{json_extract('preview_environment_id')} IN (#{preview_environment_any_owner_sql})"
          ].join(" OR ")
          [ sql, {} ]
        end

        def preview_environment_owner_sql
          <<~SQL.squish
            SELECT preview_environments.id
            FROM preview_environments
            LEFT OUTER JOIN jobs ON jobs.id = preview_environments.job_id
            LEFT OUTER JOIN repositories ON repositories.id = preview_environments.repository_id
            WHERE jobs.user_id = :user_id OR repositories.user_id = :user_id
          SQL
        end

        def preview_environment_any_owner_sql
          <<~SQL.squish
            SELECT preview_environments.id
            FROM preview_environments
            LEFT OUTER JOIN jobs ON jobs.id = preview_environments.job_id
            LEFT OUTER JOIN repositories ON repositories.id = preview_environments.repository_id
            WHERE jobs.user_id IS NOT NULL OR repositories.user_id IS NOT NULL
          SQL
        end

        def json_extract(key)
          if ActiveRecord::Base.connection.adapter_name.match?(/mysql/i)
            "JSON_UNQUOTE(JSON_EXTRACT(spawned_processes.resource_attribution, '$.#{key}'))"
          else
            "json_extract(spawned_processes.resource_attribution, '$.#{key}')"
          end
        end
      end
    end
  end
end
