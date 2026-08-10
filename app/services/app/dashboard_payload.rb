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
        "landing_queue_wait_reason" => "Queue status",
        "blocked_reason" => "Blocked reason",
        "repository" => "Repository",
        "owner" => "Owner",
        "latest" => "Latest",
        "deployment" => "Deployment",
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
          PerformanceLogging.phase("dashboard_payload.chrome", subject: subject, view: view, ownership_scope: ownership_scope) { chrome_payload }
        when "rows"
          PerformanceLogging.phase("dashboard_payload.rows", subject: subject, view: view, ownership_scope: ownership_scope) { rows_payload }
        else
          chrome = PerformanceLogging.phase("dashboard_payload.chrome", subject: subject, view: view, ownership_scope: ownership_scope) { chrome_payload }
          rows = PerformanceLogging.phase("dashboard_payload.rows", subject: subject, view: view, ownership_scope: ownership_scope) { rows_payload }
          merge_chrome_and_rows_payload(chrome, rows)
        end
      end
    end

    def chrome_payload
      health_blocked_repositories = PerformanceLogging.phase("dashboard_chrome.health_blocked_repositories", subject: subject) { health_blocked_repositories_json }

      {
        simple_mode: AppSetting.simple?,
        subject: subject,
        view: view,
        page: page,
        per_page: PER_PAGE,
        counts: PerformanceLogging.phase("dashboard_chrome.counts", subject: subject) { counts },
        ownership_scope: PerformanceLogging.phase("dashboard_chrome.ownership_scope", subject: subject) { ownership_scope_json },
        preferences: PerformanceLogging.phase("dashboard_chrome.preferences", subject: subject) { preferences_json },
        controls: PerformanceLogging.phase("dashboard_chrome.controls", subject: subject) { controls_json },
        ownership: PerformanceLogging.phase("dashboard_chrome.ownership", subject: subject) { ownership_json },
        filter: current_filter.to_h,
        landing_queue: PerformanceLogging.phase("dashboard_chrome.landing_queue", subject: subject) { landing_queue_chrome_json },
        provider_availability: PerformanceLogging.phase("dashboard_chrome.provider_availability", subject: subject) { provider_availability_by_provider },
        broken_repositories: health_blocked_repositories,
        health_blocked_repositories: health_blocked_repositories,
        smart_folders: PerformanceLogging.phase("dashboard_chrome.smart_folders", subject: subject) { smart_folders_json },
        active_smart_folder_id: active_smart_folder&.id,
        setup: PerformanceLogging.phase("dashboard_chrome.setup", subject: subject) { ::App::SetupStatus.call(user: user) },
        paths: paths_json
      }
    end

    def rows_payload
      result = PerformanceLogging.phase("dashboard_rows.current_result", subject: subject, view: view, ownership_scope: ownership_scope) { current_result }
      {
        simple_mode: AppSetting.simple?,
        subject: subject,
        view: view,
        page: page,
        per_page: PER_PAGE,
        total: result.fetch(:total),
        total_pages: total_pages(result.fetch(:total)),
        total_estimated: result.fetch(:total_estimated, false),
        active_smart_folder_id: active_smart_folder&.id,
        filter: current_filter.to_h,
        preferences: PerformanceLogging.phase("dashboard_rows.preferences", subject: subject) { preferences_json },
        controls: PerformanceLogging.phase("dashboard_rows.controls", subject: subject) { rows_controls_json },
        landing_queue: PerformanceLogging.phase("dashboard_rows.landing_queue", subject: subject, view: view) { landing_queue_json },
        items: result.fetch(:items),
        lanes: PerformanceLogging.phase("dashboard_rows.lanes", subject: subject, view: view) { lanes_json },
        kanban_limit: view == "kanban" ? kanban_limit : nil
      }
    end

    def section
      @section ||= params[:section].to_s.presence_in(SECTIONS) || "full"
    end

    private

    attr_reader :user, :params

    def provider_availability_by_provider
      @provider_availability_by_provider ||= PerformanceLogging.phase("dashboard_provider_availability.all_for_user") do
        ::App::ProviderAvailability.all_for_user(user)
      end
    end

    def provider_availability_for(provider)
      provider_availability_by_provider[provider]
    end

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
      return "epic" if AppSetting.simple?

      @subject ||= normalize_subject(params[:subject]) ||
                   normalize_subject(params[:dashboard_subject]) ||
                   normalize_subject(user.dashboard_preferences["last_subject"]) ||
                   DEFAULT_SUBJECT
    end

    def view
      return "list" if AppSetting.simple?

      @view ||= params[:view].to_s.presence_in(available_views) ||
                folder_pref_view ||
                user.dashboard_preferences.dig(subject.pluralize, "last_view").to_s.presence_in(available_views) ||
                user.dashboard_preferences["last_view"].to_s.presence_in(available_views) ||
                DEFAULT_VIEW
    end

    def available_views
      return %w[list] if AppSetting.simple?

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
      PerformanceLogging.phase("dashboard_jobs_result", view: view, ownership_scope: ownership_scope) do
        PerformanceLogging.phase("dashboard_jobs.landing_queue_snapshot", view: view) { ensure_landing_queue_snapshot! if landing_queue_visible? }
        scope = filtered_jobs_scope
        rows_only_estimate = rows_only_job_result?
        total = PerformanceLogging.phase("dashboard_jobs.total", exact: !rows_only_estimate) do
          rows_only_estimate ? nil : scope.count
        end
        scope = scope.with_latest_workflow_snapshot.preload(
          :repository,
          :user,
          :owner_user,
          :claimed_by_user,
          :tags,
          :deployment_stage_statuses,
          { dependencies: [ :depends_on_epic, { depends_on_job: :repository } ] },
          { chat_proposals: [ :chat_session, :messages ] },
          { epic: { chat_proposals: [ :chat_session, :messages ] } }
        )
        jobs = PerformanceLogging.phase("dashboard_jobs.query", page: page, view: view, rows_only_estimate: rows_only_estimate) do
          sorted_jobs(scope, limit_extra: rows_only_estimate).to_a
        end
        if rows_only_estimate
          total = estimated_total_from_page!(jobs)
        end
        @current_jobs = jobs
        PerformanceLogging.phase("dashboard_jobs.preload_runtime_state", count: jobs.size, view: view) { preload_job_runtime_state(jobs) }
        preload_epic_job_counts(jobs)
        items = PerformanceLogging.phase("dashboard_jobs.serialize", count: jobs.size, view: view) { jobs.map { |job| job_json(job) } }

        { total: total, total_estimated: rows_only_estimate, items: items }
      end
    end

    def epics_result
      PerformanceLogging.phase("dashboard_epics_result", view: view, ownership_scope: ownership_scope) do
        scope = filtered_epics_scope.includes(:owner, :repository, :owner_user, :jobs)
        total = PerformanceLogging.phase("dashboard_epics.total") { scope.count }
        epics = PerformanceLogging.phase("dashboard_epics.query", page: page, view: view) { paginate(apply_sort(scope, :epic)).to_a }
        items = PerformanceLogging.phase("dashboard_epics.serialize", count: epics.size, view: view) { epics.map { |epic| epic_json(epic) } }

        { total: total, items: items }
      end
    end

    def workflows_result
      PerformanceLogging.phase("dashboard_workflows_result", view: view, ownership_scope: ownership_scope) do
        scope = filtered_workflows_scope.includes(:steps, job: [ :repository, :user, :owner_user ])
        total = PerformanceLogging.phase("dashboard_workflows.total") { scope.count }
        workflows = PerformanceLogging.phase("dashboard_workflows.query", page: page, view: view) { paginate(apply_sort(scope, :workflow)).to_a }
        items = PerformanceLogging.phase("dashboard_workflows.serialize", count: workflows.size, view: view) { workflows.map { |workflow| workflow_json(workflow) } }

        { total: total, items: items }
      end
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
      @counts ||= PerformanceLogging.phase("dashboard_counts") do
        {
          jobs: PerformanceLogging.phase("dashboard_counts.jobs") { jobs_base_scope.count },
          epics: PerformanceLogging.phase("dashboard_counts.epics") { epics_base_scope.where.not(state: Epic::ARCHIVED_STATE).count },
          workflows: PerformanceLogging.phase("dashboard_counts.workflows") { workflows_base_scope.count }
        }
      end
    end

    def rows_controls_json
      {
        columns: column_options_json
      }
    end

    def merge_chrome_and_rows_payload(chrome, rows)
      controls = chrome.fetch(:controls).merge(rows[:controls].to_h) do |key, chrome_value, rows_value|
        key == :columns ? rows_value : chrome_value
      end

      chrome.merge(rows).merge(
        controls: controls,
        smart_folders: chrome[:smart_folders]
      )
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

    def sorted_jobs(scope, limit_extra: false)
      return landing_queue_sorted_jobs(scope) if landing_queue_position_sort?

      paginate(apply_sort(scope, :job), limit_extra: limit_extra)
    end

    def landing_queue_position_sort?
      landing_queue_visible? && sort_value(dashboard_sort(:job), "column") == "landing_queue_position"
    end

    def landing_queue_sorted_jobs(scope)
      direction = sort_value(dashboard_sort(:job), "direction") == "asc" ? :asc : :desc
      sorted = scope.reorder(
        Arel.sql("CASE WHEN jobs.landing_queue_position IS NULL THEN 1 ELSE 0 END #{direction.to_s.upcase}"),
        Arel.sql("CASE WHEN jobs.landing_queue_entry_position IS NULL THEN 1 ELSE 0 END ASC"),
        Job.arel_table[:landing_queue_entry_position].public_send(direction),
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

    def paginate(scope, limit_extra: false)
      scope.offset((page - 1) * PER_PAGE).limit(PER_PAGE + (limit_extra ? 1 : 0))
    end

    def rows_only_job_result?
      section == "rows" && subject == "job" && view == "list" && !landing_queue_position_sort?
    end

    def estimated_total_from_page!(records)
      has_next_page = records.length > PER_PAGE
      records.pop if has_next_page

      offset = (page - 1) * PER_PAGE
      offset + records.length + (has_next_page ? 1 : 0)
    end

    def preload_job_runtime_state(jobs)
      job_ids = jobs.map(&:id)
      @job_runtime_workflow_counts_by_job_id = PerformanceLogging.phase("dashboard_jobs.preload.workflow_counts", count: job_ids.size) do
        job_ids.empty? ? {} : Workflow.where(job_id: job_ids).group(:job_id).count
      end
      @job_runtime_latest_runs_by_job_id = PerformanceLogging.phase("dashboard_jobs.preload.latest_runs", count: job_ids.size) { latest_runs_for_jobs(jobs) }
      @job_runtime_latest_workflows_by_job_id = PerformanceLogging.phase("dashboard_jobs.preload.latest_workflows", count: job_ids.size) { latest_workflows_for_jobs(jobs) }
      run_ids = @job_runtime_latest_runs_by_job_id.values.map(&:id)
      @job_runtime_run_diagnostics_by_run_id = PerformanceLogging.phase("dashboard_jobs.preload.run_diagnostics", count: run_ids.size) do
        run_ids.empty? ? {} : RunDiagnostic.where(run_id: run_ids).index_by(&:run_id)
      end
      @job_runtime_active_job_ids = PerformanceLogging.phase("dashboard_jobs.preload.active_jobs", count: job_ids.size) do
        job_ids.empty? ? {} : Run.active.where(job_id: job_ids).distinct.pluck(:job_id).index_with(true)
      end
      @job_runtime_paused_job_ids = PerformanceLogging.phase("dashboard_jobs.preload.paused_jobs", count: job_ids.size) { paused_job_ids(job_ids).index_with(true) }
    end

    def paused_job_ids(job_ids)
      return [] if job_ids.empty?

      latest_by_job = @job_runtime_latest_workflows_by_job_id || latest_workflows_by_job_id(job_ids)
      latest_by_job.values.select do |workflow|
        workflow.running? && !workflow.landing_workflow? && workflow_pause_artifact?(workflow)
      end.map(&:job_id) - @job_runtime_active_job_ids.keys
    end

    def latest_runs_for_jobs(jobs)
      latest_ids = jobs.filter_map(&:latest_run_id)
      latest_ids.empty? ? {} : Run.where(id: latest_ids).index_by(&:job_id)
    end

    def latest_workflows_by_job_id(job_ids)
      return {} if job_ids.empty?

      latest_active_ids = Workflow.where(job_id: job_ids, state: %w[ queued running ]).group(:job_id).maximum(:id)
      latest_ids = Workflow.where(job_id: job_ids).group(:job_id).maximum(:id)
      selected_ids = latest_ids.merge(latest_active_ids).values
      selected_ids.empty? ? {} : Workflow.where(id: selected_ids).index_by(&:job_id)
    end

    def latest_workflows_for_jobs(jobs)
      latest_ids = jobs.filter_map(&:latest_workflow_id)
      latest_ids.empty? ? {} : Workflow.where(id: latest_ids).index_by(&:job_id)
    end

    def total_pages(total)
      return 1 if total.to_i.zero?

      (total.to_f / PER_PAGE).ceil
    end

    def paths_json
      {
        dashboard_path: AppSetting.simple? ? dashboard_epics_path : dashboard_path_for(subject),
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
      return "paused" if job_apparently_paused?(job)

      job.state
    end

    def active_workflow_trigger_kind(job)
      return nil unless summary_state(job) == "running"

      job.active_workflow_trigger_kind
    end

    def job_apparently_paused?(job)
      if defined?(@job_runtime_active_job_ids)
        return false if @job_runtime_active_job_ids.key?(job.id)
        return @job_runtime_paused_job_ids.key?(job.id)
      end

      return false if job.any_active_run?

      workflow = job.latest_workflow
      workflow&.running? && !workflow.landing_workflow? && workflow_pause_artifact?(workflow)
    end

    def workflow_pause_artifact?(workflow)
      workflow.artifact("pause_reason").present? || workflow.artifact("start_blocked_reason").present?
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

    # Precomputes true epic-level job counts for a batch of jobs, storing them
    # in @epic_job_counts and @epic_landed_job_counts for use by job_epic_json.
    # Runs two aggregate queries (one per count) keyed on epic_id so that
    # serializing N jobs with epics never causes N+1 queries, and the counts
    # reflect the full epic (not the filtered dashboard payload).
    def preload_epic_job_counts(jobs)
      epic_ids = jobs.filter_map(&:epic_id).uniq
      return if epic_ids.empty?

      @epic_job_counts = Job.where(epic_id: epic_ids).group(:epic_id).count
      @epic_landed_job_counts = Job.where(epic_id: epic_ids, state: "closed")
                                   .where(closure_reason: Epic::MERGED_JOB_CLOSURE_REASONS)
                                   .group(:epic_id).count
    end
  end
end
