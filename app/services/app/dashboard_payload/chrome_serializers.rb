module App
  class DashboardPayload
    module ChromeSerializers
      extend ActiveSupport::Concern

      # Chrome-payload serialization extracted from DashboardPayload: the smart-folder
      # list, saved preferences, controls, ownership chrome, repository-health / main-
      # branch-repair blocks, and the column / kanban-lane option lists. Mixed back in
      # via ActiveSupport::Concern, so it reads the same @user/@params, the COLUMN_LABELS
      # / JOB_KANBAN_LANES constants, and the shared *_json helpers through the ancestry.

      def smart_folders_json
        folders = SmartFolder.for_subject(subject)
                             .where("user_id IS NULL OR user_id = ?", user.id)
                             .order(Arel.sql("CASE WHEN user_id IS NULL THEN 0 ELSE 1 END"), :position, :id)

        folders.filter_map do |folder|
          count = smart_folder_count(folder)
          next unless smart_folder_visible?(folder, count)

          {
            id: folder.id,
            name: folder.name,
            key: folder.builtin_key,
            kind: folder.kind,
            position: folder.position,
            subject_type: folder.subject_type,
            visibility: folder.visibility.to_s,
            count: count,
            active: active_smart_folder&.id == folder.id,
            filter: folder.filter,
            attention_preset: folder.attention_preset,
            path: dashboard_path_for(subject, smart_folder_id: folder.id)
          }
        end
      end

      def smart_folder_visible?(folder, count)
        return true unless folder.builtin?
        return true if active_smart_folder&.id == folder.id
        return count.positive? if folder.visibility == :when_present

        true
      end

      def smart_folder_count(folder)
        case subject
        when "job"
          Jobs::Filter.from_tree(folder.filter, user: user).apply(jobs_base_scope).count
        when "workflow"
          Workflows::Filter.from_tree(folder.filter, user: user).apply(workflows_base_scope).count
        else
          filter = Epics::Filter.from_tree(folder.filter, user: user)
          scope = epics_base_scope
          scope = scope.where.not(state: Epic::ARCHIVED_STATE) unless filter.includes_archived_state?
          filter.apply(scope).count
        end
      end

      def preferences_json
        table = subject.pluralize
        {
          sort: dashboard_sort(subject),
          visible_columns: user.dashboard_visible_columns(subject),
          kanban_lanes: user.dashboard_visible_kanban_lanes(subject),
          ownership_scope: ownership_scope,
          owner_user_id: selected_owner_user&.id,
          owner_id: selected_owner_user&.id,
          raw: user.dashboard_preferences.fetch(table)
        }
      end

      def controls_json
        {
          views: VIEWS,
          ownership_scopes: ownership_scope_options_json,
          owners: owner_options.map { |owner| owner_option_json(owner) },
          sort_columns: User::DASHBOARD_SORT_COLUMNS.fetch(subject),
          sort_directions: User::DASHBOARD_SORT_DIRECTIONS,
          columns: column_options_json,
          kanban_lanes: kanban_lane_options_json,
          filter_schema: Filters::Schema.for(subject: subject.to_sym, user: user),
          filter_suggestions: filter_suggestions_json
        }
      end

      def filter_suggestions_json
        Filters::Suggestions.for(
          user: user,
          surface: "dashboard",
          subject: subject,
          active_tree: current_filter.to_h
        )
      end

      def ownership_scope_json
        {
          scope: ownership_scope,
          owner_user_id: selected_owner_user&.id,
          owner_user: owner_user_json(selected_owner_user)
        }
      end

      def ownership_json
        {
          scope: ownership_scope,
          owner_id: selected_owner_user&.id,
          team_user_count: team_user_count,
          badges_visible: team_user_count > 1
        }
      end

      def ownership_scope_options_json
        OWNERSHIP_SCOPES.map do |scope|
          {
            value: scope,
            label: scope.humanize
          }
        end
      end

      def owner_option_json(owner)
        {
          id: owner.id,
          label: owner.team_display_name,
          current: owner.id == selected_owner_user&.id
        }
      end

      def health_blocked_repositories_json
        @health_blocked_repositories_json ||= user.repositories.active.select { |repo| repo.main_health_broken? || repo.main_health_inconclusive? }.map do |repo|
          repair_status = MainHealthChangedService.new(repo).repair_status
          {
            id: repo.id,
            slug: repo.slug,
            main_health: repo.main_health,
            ci_health: repo.ci_health,
            grader_health: repo.grader_health,
            landing_paused: repo.landing_paused,
            repository_path: repository_path(repo),
            repair_path: "/api/v1/app/repositories/#{repo.id}/repair_main_branch",
            main_branch_repair: main_branch_repair_json(repair_status)
          }
        end
      end

      def main_branch_repair_json(status)
        {
          enabled: status[:enabled],
          failed_open_jobs_count: status[:failed_open_jobs_count],
          max_open_failed_jobs: status[:max_open_failed_jobs],
          blocked_reason: status[:blocked_reason],
          can_request: status[:can_request],
          can_spawn: status[:can_spawn],
          blocking_job: repair_job_json(status[:blocking_job]),
          failed_jobs: status[:failed_jobs].map { |job| repair_job_json(job) }
        }
      end

      def repair_job_json(job)
        return nil unless job

        {
          id: job.id,
          slug: job.slug,
          state: job.state,
          title: job.title,
          job_path: job_path(job)
        }
      end

      def column_options_json
        table = subject.pluralize
        {
          required: required_columns_for(table).map { |column| column_json(table, column) },
          optional: User::DASHBOARD_OPTIONAL_COLUMNS.fetch(table).map { |column| column_json(table, column) }
        }
      end

      def required_columns_for(table)
        return %w[checkbox landing_queue_position landing_queue_blocked_reason issue] if table == "jobs" && landing_queue_visible?

        User::DASHBOARD_REQUIRED_COLUMNS.fetch(table)
      end

      def column_json(table, column)
        {
          key: column,
          title: COLUMN_LABELS.dig(table, column) || column.humanize
        }
      end

      def kanban_lane_options_json
        User::DASHBOARD_KANBAN_LANES.fetch(subject.pluralize).map do |lane|
          {
            key: lane,
            title: kanban_lane_title(lane)
          }
        end
      end

      def kanban_lane_title(lane)
        return JOB_KANBAN_LANES.find { |definition| definition.fetch(:key) == lane }&.fetch(:title) || lane.humanize if subject == "job"

        lane.humanize
      end
    end
  end
end
