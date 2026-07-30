module App
  class DashboardPayload
    include Rails.application.routes.url_helpers
    include OwnershipScoping
    include KanbanLanes
    include LandingQueue
    include RecordSerializers
    include ChromeSerializers

    SUBJECTS = %w[job epic workflow].freeze
    VIEWS = %w[list kanban].freeze
    # Ownership-scope constants shared across the OwnershipScoping and
    # ChromeSerializers concerns; kept on the class body so both resolve them
    # via Module.nesting (a constant in one concern is invisible to another).
    OWNERSHIP_SCOPES = %w[mine team claimable user].freeze
    DEFAULT_OWNERSHIP_SCOPE = "mine"
    USER_FOCUSED_SUBJECTS = [].freeze
    TEAM_FOCUSED_SUBJECTS = %w[epic job workflow].freeze
    SECTIONS = %w[full chrome rows].freeze
    DEFAULT_SUBJECT = "epic"
    DEFAULT_VIEW = "list"
    FOLDER_PREFERENCE_DEFAULTS = {
      [ "epic", "null" ] => { "view" => "kanban" },
      [ "epic", "epics_mine" ] => { "view" => "kanban" },
      [ "epic", "epics_claimable" ] => { "view" => "list" },
      [ "job", "landing_queue" ] => { "sort_column" => "landing_queue_position", "sort_direction" => "asc" }
    }.freeze
    PER_PAGE = 25
    KANBAN_LIMIT_OPTIONS = [ 10, 25, 50, 100 ].freeze
    KANBAN_PER_PAGE = 100
    JOB_KANBAN_LANES = [
      { key: "blocked", title: "Blocked" },
      { key: "queued", title: "Queued" },
      { key: "running", title: "Running" },
      { key: "succeeded", title: "Succeeded" },
      { key: "landing", title: "Landing" },
      { key: "failed", title: "Failed" }
    ].freeze
    WORKFLOW_DONE_STATES = %w[succeeded failed cancelled].freeze
    COLUMN_LABELS = {
      "epics" => {
        "epic" => "Epic",
        "state" => "State",
        "owner" => "Owner",
        "repository" => "Repository",
        "updated" => "Updated",
        "created_at" => "Created at",
        "updated_at" => "Updated at",
        "done_at" => "Done at",
        "archived_at" => "Archived at"
      },
      "jobs" => {
        "checkbox" => "Checkbox",
        "issue" => "Issue",
        "state" => "State",
        "landing_queue_position" => "Queue",
        "landing_queue_blocked_reason" => "Blocked reason",
        "blocked_reason" => "Blocked reason",
        "repository" => "Repository",
        "owner" => "Owner",
        "latest" => "Latest",
        "workflows_count" => "Workflows count",
        "started" => "Started",
        "commits_behind_base" => "Behind",
        "created_at" => "Created at",
        "updated_at" => "Updated at",
        "started_at" => "Started at",
        "finished_at" => "Finished at",
        "approved_at" => "Approved at",
        "dependencies_overridden_at" => "Dependencies overridden at",
        "last_feedback_addressed_at" => "Last feedback addressed at",
        "last_seen_comment_at" => "Last seen comment at",
        "pr_mergeable_checked_at" => "PR mergeable checked at"
      },
      "workflows" => {
        "workflow" => "Workflow",
        "job" => "Job",
        "trigger" => "Trigger",
        "state" => "State",
        "started" => "Started",
        "finished" => "Finished",
        "agent" => "Agent",
        "created_at" => "Created at",
        "updated_at" => "Updated at",
        "started_at" => "Started at",
        "finished_at" => "Finished at",
        "cleaned_up_at" => "Cleaned up at"
      }
    }.freeze

    class InvalidScope < StandardError; end

    def self.call(user:, params:)
      new(user: user, params: params).call
    end

    def initialize(user:, params:)
      @user = user
      @params = params
    end

    def call
      PerformanceLogging.phase("dashboard_payload", subject: subject, view: view, ownership_scope: ownership_scope) do
        SmartFolder.ensure_builtins_for_subject!(subject)

        case section
        when "chrome"
          chrome_payload
        when "rows"
          rows_payload
        else
          chrome_payload.merge(rows_payload)
        end
      end
    end

    def chrome_payload
      {
        subject: subject,
        view: view,
        page: page,
        per_page: PER_PAGE,
        counts: counts,
        ownership_scope: ownership_scope_json,
        preferences: preferences_json,
        controls: controls_json,
        ownership: ownership_json,
        filter: current_filter.to_h,
        landing_queue: landing_queue_chrome_json,
        broken_repositories: health_blocked_repositories_json,
        health_blocked_repositories: health_blocked_repositories_json,
        smart_folders: smart_folders_json,
        active_smart_folder_id: active_smart_folder&.id,
        setup: ::App::SetupStatus.call(user: user),
        paths: paths_json
      }
    end

    def rows_payload
      {
        subject: subject,
        view: view,
        page: page,
        per_page: PER_PAGE,
        total: current_result.fetch(:total),
        total_pages: total_pages(current_result.fetch(:total)),
        landing_queue: landing_queue_json,
        items: current_result.fetch(:items),
        lanes: lanes_json,
        kanban_limit: view == "kanban" ? kanban_limit : nil
      }
    end

    def section
      @section ||= params[:section].to_s.presence_in(SECTIONS) || "full"
    end

    private

    attr_reader :user, :params

    def current_result
      @current_result ||= case subject
      when "job"
        jobs_result
      when "workflow"
        workflows_result
      else
        epics_result
      end
    end

    def current_filter
      case subject
      when "job"
        jobs_filter
      when "workflow"
        workflows_filter
      else
        epics_filter
      end
    end

    def subject
      @subject ||= normalize_subject(params[:subject]) ||
                   normalize_subject(params[:dashboard_subject]) ||
                   normalize_subject(user.dashboard_preferences["last_subject"]) ||
                   DEFAULT_SUBJECT
    end

    def view
      @view ||= params[:view].to_s.presence_in(available_views) ||
                folder_pref_view ||
                user.dashboard_preferences.dig(subject.pluralize, "last_view").to_s.presence_in(available_views) ||
                user.dashboard_preferences["last_view"].to_s.presence_in(available_views) ||
                DEFAULT_VIEW
    end

    def available_views
      subject == "workflow" ? VIEWS : VIEWS + %w[dependencies]
    end

    def folder_pref_view
      slot = active_folder_preference_slot
      return slot["view"].to_s.presence_in(available_views) if slot.key?("view")

      folder_preference_default("view").to_s.presence_in(available_views)
    end

    def page
      @page ||= [ Integer(params[:page], exception: false).to_i, 1 ].max
    end

    def active_repo_ids
      @active_repo_ids ||= active_repositories_scope.pluck(:id)
    end

    def active_repositories_scope
      return Repository.active if subject == "epic"
      return Repository.active if mine_scope? || team_scope? || user_scope? || claimable_scope?

      Repository.active.where(user_id: user.id)
    end

    def jobs_base_scope
      @jobs_base_scope ||= apply_ownership_scope(
        Job.where(repository_id: active_repo_ids),
        :job
      )
    end

    def epics_base_scope
      @epics_base_scope ||= apply_ownership_scope(Epic.where(repository_id: active_repo_ids), :epic)
    end

    def workflows_base_scope
      @workflows_base_scope ||= apply_ownership_scope(
        Workflow.joins(:job).where(jobs: { repository_id: active_repo_ids }),
        :workflow
      )
    end

    def active_smart_folder
      @active_smart_folder ||= begin
        id = Integer(params[:smart_folder_id], exception: false)
        if id.nil? && !param_key?(:smart_folder_id)
          id = Integer(user.dashboard_preferences.dig(subject.pluralize, "last_smart_folder_id"), exception: false)
        end

        if id
          SmartFolder.for_subject(subject)
                     .where("user_id IS NULL OR user_id = ?", user.id)
                     .find_by(id: id)
        elsif default_inbox_smart_folder?
          SmartFolder.find_builtin_by_attention("inbox")
        end
      end
    end

    def active_folder_key_for_prefs
      @active_folder_key_for_prefs ||= begin
        id = Integer(params[:smart_folder_id], exception: false)
        unless id || param_key?(:smart_folder_id)
          id = Integer(user.dashboard_preferences.dig(subject.pluralize, "last_smart_folder_id"), exception: false)
        end

        if id.nil? && default_inbox_smart_folder?
          id = SmartFolder.find_builtin_by_attention("inbox")&.id
        end

        id&.to_s || "null"
      end
    end

    def active_folder_builtin_key
      @active_folder_builtin_key ||= begin
        id_str = active_folder_key_for_prefs
        return "null" if id_str == "null"

        folder = SmartFolder.for_subject(subject).where(user_id: nil).builtin.find_by(id: id_str.to_i)
        return "null" unless folder

        definition = SmartFolder::BUILTINS_BY_SUBJECT.fetch(subject, []).find do |candidate|
          candidate.fetch(:name) == folder.name
        end
        definition&.fetch(:key) || "null"
      end
    end

    def active_folder_preference_slot
      user.dashboard_preferences.dig(subject.pluralize, "folder_prefs", active_folder_key_for_prefs) || {}
    end

    def folder_preference_default(key)
      FOLDER_PREFERENCE_DEFAULTS.dig([ subject, active_folder_builtin_key ], key)
    end

    def dashboard_sort(subject_name = subject)
      normalized_subject = subject_name.to_s.delete_suffix("s")
      subject_preferences = user.dashboard_preferences.fetch(normalized_subject.pluralize)
      slot = normalized_subject == subject ? active_folder_preference_slot : {}

      column = params[:sort_column].to_s.presence_in(User::DASHBOARD_SORT_COLUMNS.fetch(normalized_subject)) ||
               slot["sort_column"].to_s.presence_in(User::DASHBOARD_SORT_COLUMNS.fetch(normalized_subject)) ||
               folder_sort_default(normalized_subject, "sort_column").to_s.presence_in(User::DASHBOARD_SORT_COLUMNS.fetch(normalized_subject)) ||
               subject_preferences["sort_column"].to_s.presence_in(User::DASHBOARD_SORT_COLUMNS.fetch(normalized_subject)) ||
               User::DASHBOARD_SORT_DEFAULTS.fetch(normalized_subject).fetch("column")
      direction = params[:sort_direction].to_s.presence_in(User::DASHBOARD_SORT_DIRECTIONS) ||
                  slot["sort_direction"].to_s.presence_in(User::DASHBOARD_SORT_DIRECTIONS) ||
                  folder_sort_default(normalized_subject, "sort_direction").to_s.presence_in(User::DASHBOARD_SORT_DIRECTIONS) ||
                  subject_preferences["sort_direction"].to_s.presence_in(User::DASHBOARD_SORT_DIRECTIONS) ||
                  User::DASHBOARD_SORT_DEFAULTS.fetch(normalized_subject).fetch("direction")

      return { column: column, direction: direction } if normalized_subject == "job"

      { "column" => column, "direction" => direction }
    end

    def folder_sort_default(subject_name, key)
      return unless subject_name == subject

      folder_preference_default(key)
    end

    def default_inbox_smart_folder?
      subject == "job" &&
        params[:view] == "list" &&
        !param_key?(:smart_folder_id) &&
        !filter_param_present?
    end

    def filter_param_present?
      params[Filters::QueryParam::PARAM_NAME].present? ||
        Jobs::Filter::LEGACY_URL_KEYS.any? { |key| params[key].present? }
    end

    def param_key?(key)
      params.key?(key) || params.key?(key.to_s)
    end

    def jobs_result
      ensure_landing_queue_snapshot! if landing_queue_visible?
      scope = filtered_jobs_scope
      total = scope.count
      scope = scope.with_latest_workflow_snapshot.preload(:repository, :user, :owner_user, :claimed_by_user, :tags, :workflows, :runs, chat_proposals: [ :chat_session, :messages ], epic: { chat_proposals: [ :chat_session, :messages ] })
      jobs = sorted_jobs(scope).to_a
      @current_jobs = jobs
      items = jobs.map { |job| job_json(job) }

      { total: total, items: items }
    end

    def epics_result
      scope = filtered_epics_scope.includes(:owner, :repository, :owner_user, :jobs)
      total = scope.count
      items = paginate(apply_sort(scope, :epic)).map { |epic| epic_json(epic) }

      { total: total, items: items }
    end

    def workflows_result
      scope = filtered_workflows_scope.includes(:steps, job: [ :repository, :user, :owner_user ])
      total = scope.count
      items = paginate(apply_sort(scope, :workflow)).map { |workflow| workflow_json(workflow) }

      { total: total, items: items }
    end

    def jobs_filter
      @jobs_filter ||= Jobs::Filter.from_params(params, smart_folder: active_smart_folder_for_filter, user: user)
    end

    def filtered_jobs_scope
      @filtered_jobs_scope ||= jobs_filter.apply(jobs_base_scope)
    end

    def epics_filter
      @epics_filter ||= Epics::Filter.from_params(params, smart_folder: active_smart_folder_for_filter, user: user)
    end

    def filtered_epics_scope
      @filtered_epics_scope ||= begin
        scope = epics_base_scope
        scope = scope.where.not(state: Epic::ARCHIVED_STATE) unless epics_filter.includes_archived_state?
        epics_filter.apply(scope)
      end
    end

    def workflows_filter
      @workflows_filter ||= Workflows::Filter.from_params(params, smart_folder: active_smart_folder_for_filter, user: user)
    end

    def active_smart_folder_for_filter
      url_filter.active? ? nil : active_smart_folder
    end

    def url_filter
      @url_filter ||= case subject
      when "job"
        Jobs::Filter.from_params(params, user: user)
      when "workflow"
        Workflows::Filter.from_params(params, user: user)
      else
        Epics::Filter.from_params(params, user: user)
      end
    end

    def filtered_workflows_scope
      @filtered_workflows_scope ||= begin
        scope = workflows_base_scope
        workflows_filter.apply(scope)
      end
    end

    def counts
      @counts ||= {
        jobs: jobs_base_scope.count,
        epics: epics_base_scope.where.not(state: Epic::ARCHIVED_STATE).count,
        workflows: workflows_base_scope.count
      }
    end

    def apply_sort(scope, subject_name)
      sort = dashboard_sort(subject_name)
      column = sort_value(sort, "column")
      direction = sort_value(sort, "direction") == "asc" ? :asc : :desc

      case [ subject_name.to_s, column ]
      when [ "job", "title" ]
        scope.reorder(Job.arel_table[:issue_title].public_send(direction), Job.arel_table[:id].public_send(direction))
      when [ "job", "state" ]
        scope.reorder(Job.arel_table[:state].public_send(direction), Job.arel_table[:id].public_send(direction))
      when [ "job", "repository" ]
        scope.joins(:repository).reorder(Repository.arel_table[:name].public_send(direction), Job.arel_table[:id].public_send(direction))
      when [ "job", "landing_queue_position" ]
        scope.reorder(Arel.sql("COALESCE(jobs.approved_at, jobs.updated_at) #{direction.to_s.upcase}"), Job.arel_table[:id].public_send(direction))
      when [ "job", "started_at" ]
        scope.reorder(Job.arel_table[:started_at].public_send(direction), Job.arel_table[:id].public_send(direction))
      when [ "job", "priority" ]
        scope.reorder(
          Arel.sql("CASE jobs.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END #{direction.to_s.upcase}"),
          Job.arel_table[:id].public_send(direction)
        )
      when [ "job", "commits_behind_base" ]
        scope.reorder(
          Arel.sql("CASE WHEN jobs.commits_behind_base IS NULL THEN 1 ELSE 0 END ASC"),
          Job.arel_table[:commits_behind_base].public_send(direction),
          Job.arel_table[:id].public_send(direction)
        )
      when [ "epic", "title" ]
        scope.reorder(Epic.arel_table[:title].public_send(direction), Epic.arel_table[:id].public_send(direction))
      when [ "epic", "state" ]
        scope.reorder(Epic.arel_table[:state].public_send(direction), Epic.arel_table[:id].public_send(direction))
      when [ "epic", "repository" ]
        scope.joins(:repository).reorder(Repository.arel_table[:name].public_send(direction), Epic.arel_table[:id].public_send(direction))
      when [ "workflow", "title" ]
        scope.reorder(Workflow.arel_table[:id].public_send(direction))
      when [ "workflow", "state" ]
        scope.reorder(Workflow.arel_table[:state].public_send(direction), Workflow.arel_table[:id].public_send(direction))
      when [ "workflow", "finished_at" ]
        scope.reorder(Workflow.arel_table[:finished_at].public_send(direction), Workflow.arel_table[:id].public_send(direction))
      else
        default_sort(scope, subject_name, direction)
      end
    end

    def sorted_jobs(scope)
      return landing_queue_sorted_jobs(scope) if landing_queue_position_sort?

      paginate(apply_sort(scope, :job))
    end

    def landing_queue_position_sort?
      landing_queue_visible? && sort_value(dashboard_sort(:job), "column") == "landing_queue_position"
    end

    def landing_queue_sorted_jobs(scope)
      direction = sort_value(dashboard_sort(:job), "direction") == "asc" ? :asc : :desc
      sorted = scope.reorder(
        Arel.sql("CASE WHEN jobs.landing_queue_position IS NULL THEN 1 ELSE 0 END ASC"),
        Job.arel_table[:landing_queue_position].public_send(direction),
        Job.arel_table[:id].public_send(direction)
      )
      paginate(sorted)
    end

    def default_sort(scope, subject_name, direction)
      case subject_name.to_s
      when "epic"
        scope.reorder(Epic.arel_table[:updated_at].public_send(direction), Epic.arel_table[:id].public_send(direction))
      when "workflow"
        scope.reorder(Workflow.arel_table[:started_at].public_send(direction), Workflow.arel_table[:id].public_send(direction))
      else
        scope.reorder(Job.arel_table[:created_at].public_send(direction), Job.arel_table[:id].public_send(direction))
      end
    end

    def paginate(scope)
      scope.offset((page - 1) * PER_PAGE).limit(PER_PAGE)
    end

    def total_pages(total)
      return 1 if total.to_i.zero?

      (total.to_f / PER_PAGE).ceil
    end

    def paths_json
      {
        dashboard_path: dashboard_path_for(subject),
        dashboard_jobs_path: dashboard_jobs_path,
        dashboard_epics_path: dashboard_epics_path,
        dashboard_workflows_path: dashboard_workflows_path,
        new_epic_path: new_epic_path,
        new_job_path: new_job_path,
        app_dashboard_path: "/api/v1/app/dashboard"
      }
    end

    def dashboard_path_for(target_subject, extra = {})
      extra = ownership_query_params.merge(extra)
      case target_subject.to_s
      when "epic"
        dashboard_epics_path(extra)
      when "workflow"
        dashboard_workflows_path(extra)
      else
        dashboard_jobs_path(extra)
      end
    end

    def ownership_query_params
      query = { ownership_scope: ownership_scope }
      query[:owner_id] = selected_owner_user.id if ownership_scope == "user"
      query
    end

    def repository_json(repository)
      {
        id: repository.id,
        slug: repository.slug,
        repository_path: repository_path(repository)
      }
    end

    def tag_json(tag)
      {
        id: tag.id,
        name: tag.name,
        color: tag.color
      }
    end

    def owner_user_json(owner)
      return nil unless owner

      {
        id: owner.id,
        name: owner.display_name,
        email_address: owner.email_address
      }
    end

    def summary_state(job)
      return "preempted" if job.closure_reason == "preempted"
      return "preempted" if job.closure_reason&.start_with?("external_pr_")

      job.state
    end

    def active_workflow_trigger_kind(job)
      return nil unless summary_state(job) == "running"

      job.active_workflow_trigger_kind
    end

    def ownership_param_present?
      params.key?(:scope) || params.key?(:ownership_scope) || params.key?(:owner_id) || params.key?(:owner_user_id)
    end

    def legacy_scope_param?
      params.key?(:scope) && !params.key?(:ownership_scope)
    end

    def normalize_subject(value)
      normalized = value.to_s.singularize
      normalized.presence_in(SUBJECTS)
    end

    def sort_value(sort, key)
      sort[key] || sort[key.to_sym]
    end
  end
end
