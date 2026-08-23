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
        folders = PerformanceLogging.phase("dashboard_smart_folders.query", subject: subject) do
          SmartFolder.for_subject(subject)
                     .where("user_id IS NULL OR user_id = ?", user.id)
                     .order(Arel.sql("CASE WHEN user_id IS NULL THEN 0 ELSE 1 END"), :position, :id)
                     .to_a
        end

        folder_counts = smart_folder_counts(folders)

        folders.filter_map do |folder|
          count = folder_counts[folder.id]
          next unless smart_folder_visible?(folder, count)

          json = {
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
          json[:blocked_count] = queued_blocked_job_count if folder.builtin_key == "queued" && subject == "job"
          json
        end
      end

      def smart_folder_visible?(folder, count)
        return true unless folder.builtin?
        return true if active_smart_folder&.id == folder.id
        return count.to_i.positive? if folder.visibility == :when_present

        true
      end

      def queued_blocked_job_count
        @queued_blocked_job_count ||= begin
          queued_folder_filter = SmartFolder::JOB_BUILTINS
                                            .find { |definition| definition.fetch(:key) == "queued" }
                                            .fetch(:filter)
          queued_scope = Jobs::Filter.from_tree(queued_folder_filter, user: user)
                                     .apply(jobs_base_scope)
                                     .where(state: "queued")
                                     .select(:id)
          queued_job_ids = queued_scope.pluck(:id)
          legacy_blocked_job_ids = legacy_queued_blocked_job_ids(queued_job_ids)
          work_unit_blocked_job_ids = WorkUnits::Ownership.blocked_job_ids(queued_job_ids).to_a
          (legacy_blocked_job_ids | work_unit_blocked_job_ids).size
        end
      end

      def legacy_queued_blocked_job_ids(queued_job_ids)
        ids = Array(queued_job_ids).map(&:to_i).select(&:positive?)
        return [] if ids.empty?

        base_scope = Workflow.where(job_id: ids, state: "queued")
                             .where("artifacts LIKE ?", '%"start_blocked_reason"%')
        WorkUnits::Ownership
          .legacy_active_workflows_scope(ids, base_scope: base_scope)
          .includes(:work_unit)
          .select { |workflow| WorkUnits::StartBlock.for(workflow).reason.present? }
          .map(&:job_id)
          .uniq
      end

      def smart_folder_counts(folders)
        return {} if folders.empty?

        volatile, cacheable = folders.partition { |folder| volatile_smart_folder_count?(folder) }
        cacheable = cacheable.select { |folder| smart_folder_count_needed?(folder) }
        cached_counts = cacheable.empty? ? {} : Rails.cache.fetch(smart_folder_counts_cache_key(cacheable), expires_in: 2.minutes) do
          PerformanceLogging.phase("dashboard_smart_folders.counts", subject: subject, count: cacheable.size) do
            cacheable.to_h do |folder|
              count = PerformanceLogging.phase("dashboard_smart_folders.count", subject: subject, folder_id: folder.id, builtin_key: folder.builtin_key) do
                smart_folder_count_uncached(folder)
              end
              [ folder.id, count ]
            end
          end
        end
        live_counts = volatile.to_h do |folder|
          count = PerformanceLogging.phase("dashboard_smart_folders.volatile_count", subject: subject, folder_id: folder.id, builtin_key: folder.builtin_key) do
            smart_folder_count_uncached(folder)
          end
          [ folder.id, count ]
        end
        cached_counts.merge(live_counts)
      end

      def volatile_smart_folder_count?(folder)
        return false unless subject == "job" && folder.builtin?

        folder.builtin_key.in?(%w[in_progress paused queued landing_queue])
      end

      def smart_folder_count_needed?(folder)
        return true if active_smart_folder&.id == folder.id
        return true unless folder.builtin?
        return false if folder.visibility == :on_demand

        folder.visibility.in?([ :always, :when_present ])
      end

      def smart_folder_counts_cache_key(folders)
        [
          "dashboard_smart_folder_counts",
          user.id,
          subject,
          ownership_scope,
          selected_owner_user&.id,
          active_repo_ids,
          folders.map(&:id),
          folders.map { |folder| folder.updated_at.to_i }.max
        ]
      end

      def smart_folder_count_uncached(folder)
        case subject
        when "job"
          count = fast_builtin_job_count(folder)
          return count unless count.nil?

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

      def fast_builtin_job_count(folder)
        return nil unless folder.builtin?

        case folder.builtin_key
        when "inbox" then fast_inbox_job_count
        else nil
        end
      end

      def fast_job_builtin_scope
        jobs_base_scope
          .where(kind: Filters::Chips::Jobs::JobType::USER_KINDS)
          .merge(Job.effectively_owned_by(user))
      end

      def fast_inbox_job_count
        scope = fast_job_builtin_scope.open_threads.without_active_workflows
        scope.where(
          <<~SQL.squish,
            (
              jobs.last_seen_comment_at IS NOT NULL
              AND (jobs.last_feedback_addressed_at IS NULL OR jobs.last_seen_comment_at > jobs.last_feedback_addressed_at)
              AND jobs.state NOT IN (:feedback_excluded_states)
            )
            OR jobs.state = :failed_state
            OR (
              jobs.landing_failure_reason IS NOT NULL
              AND jobs.landing_failure_reason NOT LIKE :start_blocker_prefix
            )
            OR jobs.validity IN (:review_validities)
            OR jobs.state = :implemented_state
          SQL
          feedback_excluded_states: %w[ triaging queued running landing ],
          failed_state: "failed",
          start_blocker_prefix: "#{LandingQueueReentry::START_BLOCKER_PREFIX}%",
          review_validities: %w[ duplicate already_implemented ],
          implemented_state: "implemented"
        ).count
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
        PerformanceLogging.phase("dashboard_controls", subject: subject) do
          {
            views: available_views,
            ownership_scopes: ownership_scope_options_json,
            owners: PerformanceLogging.phase("dashboard_controls.owners", subject: subject) { owner_options.map { |owner| owner_option_json(owner) } },
            sort_columns: User::DASHBOARD_SORT_COLUMNS.fetch(subject),
            sort_directions: User::DASHBOARD_SORT_DIRECTIONS,
            columns: column_options_json,
            kanban_lanes: kanban_lane_options_json,
            filter_schema: PerformanceLogging.phase("dashboard_controls.filter_schema", subject: subject) { Filters::Schema.for(subject: subject.to_sym, user: user) },
            filter_suggestions: PerformanceLogging.phase("dashboard_controls.filter_suggestions", subject: subject) { filter_suggestions_json }
          }
        end
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
        @health_blocked_repositories_json ||= PerformanceLogging.phase("dashboard_health_blocked_repositories", subject: subject) do
          user.repositories.active.select { |repo| repo.main_health_broken? || repo.main_health_inconclusive? }.map do |repo|
            repair_status = PerformanceLogging.phase("dashboard_health_blocked_repositories.repair_status", repository_id: repo.id) do
              MainHealthChangedService.new(repo).repair_status
            end
            {
              id: repo.id,
              slug: repo.slug,
              main_health: repo.main_health,
              ci_health: repo.ci_health,
              grader_health: repo.grader_health,
              landing_paused: repo.landing_paused,
              main_branch_repair_blocks_work: repo.main_branch_repair_blocks_work?,
              repository_path: repository_path(repo),
              repair_path: "/api/v1/app/repositories/#{repo.id}/repair_main_branch",
              main_branch_repair: main_branch_repair_json(repair_status)
            }
          end
        end
      end

      def untagged_issues_json
        @untagged_issues_json ||= PerformanceLogging.phase("dashboard_untagged_issues", subject: subject) do
          repositories = active_repositories_scope.where("untagged_open_issue_count > 0")
          repositories_json = repositories.map { |repo| untagged_issue_repository_json(repo) }
          {
            total: repositories_json.sum { |entry| entry.fetch(:count) },
            repositories: repositories_json
          }
        end
      end

      def untagged_issue_repository_json(repository)
        {
          id: repository.id,
          slug: repository.slug,
          count: repository.untagged_open_issue_count,
          issues_path: repository_path(repository, tab: "github_issues")
        }
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
        return %w[checkbox landing_queue_position landing_queue_wait_reason issue] if table == "jobs" && landing_queue_visible?
        return %w[checkbox blocked_reason issue] if table == "jobs" && blocked_folder_visible?

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
