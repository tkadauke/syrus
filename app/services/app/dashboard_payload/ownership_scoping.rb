module App
  class DashboardPayload
    module OwnershipScoping
      extend ActiveSupport::Concern

      # Ownership/scope-filtering extracted from DashboardPayload: resolving the
      # active ownership scope (mine/team/claimable/user), the selected owner, and
      # applying those scopes (incl. the default epic-work scope) to the job/epic/
      # workflow queries. Mixed back in, so it reads the same @user/@params. The
      # OWNERSHIP_SCOPES / TEAM_FOCUSED_SUBJECTS constants live on the DashboardPayload
      # class body (not here) so sibling concerns like ChromeSerializers can resolve
      # them through Module.nesting — a constant defined in one included concern is
      # NOT visible to a method lexically scoped inside another.

      def ownership_scope
        @ownership_scope ||= begin
          raw_scope = params[:scope].presence || params[:ownership_scope].presence
          raw_scope ||= "user" if params[:owner_id].present? || params[:owner_user_id].present?
          raw_scope ||= user.dashboard_preferences.dig(subject.pluralize, "ownership_scope").to_s.presence
          raw_scope = "team" if default_team_focused_subject? && raw_scope == "mine" && !ownership_param_present?
          raw_scope ||= user.dashboard_preferences["last_ownership_scope"].to_s.presence unless default_team_focused_subject?
          raw_scope ||= "team" if default_team_focused_subject?
          raw_scope ||= DEFAULT_OWNERSHIP_SCOPE

          normalized = raw_scope.to_s
          raise InvalidScope, "Unknown dashboard scope: #{raw_scope}" unless OWNERSHIP_SCOPES.include?(normalized)

          normalized
        end
      end

      def default_team_focused_subject?
        TEAM_FOCUSED_SUBJECTS.include?(subject)
      end

      def selected_owner_user
        @selected_owner_user ||= begin
          case ownership_scope
          when "mine"
            user
          when "user"
            id = Integer(
              params[:owner_id].presence ||
              params[:owner_user_id].presence ||
              user.dashboard_preferences.dig(subject.pluralize, "owner_id") ||
              user.dashboard_preferences["last_owner_user_id"],
              exception: false
            )
            raise InvalidScope, "owner_id is required for dashboard scope user" unless id

            User.find_by(id: id) || raise(InvalidScope, "Unknown dashboard owner user: #{id}")
          end
        end
      end

      def selected_owner_id
        selected_owner_user&.id || user.id
      end

      def mine_scope?
        ownership_scope == "mine"
      end

      def team_scope?
        ownership_scope == "team"
      end

      def claimable_scope?
        ownership_scope == "claimable"
      end

      def user_scope?
        ownership_scope == "user"
      end

      def team_user_count
        @team_user_count ||= User.count
      end

      def owner_options
        @owner_options ||= User.order(Arel.sql("LOWER(email_address) ASC"), :id).to_a
      end

      def apply_ownership_scope(scope, subject_name)
        case ownership_scope
        when "team"
          scope
        when "mine", "user"
          return apply_default_epic_work_scope(scope) if default_epic_work_scope?(subject_name)

          owner_id = selected_owner_user.id
          case subject_name.to_s
          when "workflow"
            if job_user_fallback_scope?
              scope.where("jobs.owner_user_id = :owner_id OR jobs.user_id = :owner_id", owner_id: owner_id)
            else
              scope.where(jobs: { owner_user_id: owner_id })
            end
          when "job"
            if job_user_fallback_scope?
              scope.where("jobs.owner_user_id = :owner_id OR jobs.user_id = :owner_id", owner_id: owner_id)
            else
              scope.where(owner_user_id: owner_id)
            end
          when "epic"
            scope.where(epic_owner_condition(owner_id))
          end
        when "claimable"
          case subject_name.to_s
          when "workflow"
            # Epicless jobs are never claimable — they default to their creator
            # as owner. Only an unowned Epic child is claimable (by claiming its
            # Epic). Requiring epic_id keeps legacy NULL-owner epicless jobs out
            # of the pool even before the ownership backfill runs.
            scope.where(jobs: { owner_user_id: nil }).where.not(jobs: { epic_id: nil })
          when "epic"
            scope.where(owner_id: nil, owner_user_id: nil, state: %w[backlog ready])
          else
            scope.where(owner_user_id: nil).where.not(epic_id: nil)
          end
        end
      end

      def default_epic_work_scope?(subject_name = subject)
        subject_name.to_s == "epic" && mine_scope? && (!ownership_param_present? || legacy_scope_param?)
      end

      def apply_default_epic_work_scope(scope)
        scope.where(
          <<~SQL.squish,
            epics.owner_user_id = :owner_id
            OR epics.owner_id = :owner_id
            OR (
              epics.owner_user_id IS NULL
              AND epics.owner_id IS NULL
              AND epics.state IN (:claimable_states)
            )
          SQL
          owner_id: user.id,
          claimable_states: %w[backlog ready]
        )
      end

      def job_user_fallback_scope?
        return true if user_scope?
        return false unless mine_scope?
        return false if ownership_param_present?
        return false if selected_owner_has_owner_user_records?

        true
      end

      def selected_owner_has_owner_user_records?
        case subject
        when "workflow"
          Workflow.joins(:job).where(jobs: { repository_id: active_repo_ids, owner_user_id: selected_owner_id }).exists?
        when "job"
          Job.where(repository_id: active_repo_ids, owner_user_id: selected_owner_id).exists?
        else
          false
        end
      end

      def epic_owner_condition(owner_id)
        table = Epic.arel_table
        table[:owner_user_id].eq(owner_id).or(table[:owner_id].eq(owner_id))
      end
    end
  end
end
