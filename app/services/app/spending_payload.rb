module App
  class SpendingPayload
    DEFAULT_WINDOW_DAYS = 90
    TOP_RUN_LIMIT = 10
    TREND_LIMIT_DAYS = 370

    def initialize(user:, params: {})
      @user = user
      @params = params
      @today = Time.zone.today
      @start_date = parse_date(params[:start_date]) || (@today - DEFAULT_WINDOW_DAYS.days)
      @end_date = parse_date(params[:end_date]) || @today
      @start_date, @end_date = @end_date, @start_date if @start_date > @end_date
      @repository_id = params[:repository_id].presence
      @epic_id = params[:epic_id].presence
      @agent_provider = parse_agent_provider(params[:agent_provider])
    end

    def as_json(*)
      {
        scope: scope_json,
        filters: filters_json,
        totals: totals_json,
        breakdowns: {
          epics: epic_breakdown,
          users: user_breakdown,
          repositories: repository_breakdown,
          trigger_kinds: trigger_kind_breakdown
        },
        top_runs: top_runs,
        trend: trend
      }
    end

    private

    attr_reader :user, :start_date, :end_date, :today, :agent_provider, :repository_id, :epic_id

    def scope_json
      {
        admin: user.admin?,
        user_id: user.id,
        label: user.admin? ? "All users" : user.display_name
      }
    end

    def filters_json
      {
        start_date: start_date.iso8601,
        end_date: end_date.iso8601,
        default_window_days: DEFAULT_WINDOW_DAYS,
        agent_provider: agent_provider,
        repository_id: repository_id&.to_i,
        epic_id: epic_id&.to_i,
        agent_providers: available_agent_providers
      }
    end

    def totals_json
      {
        week_usd: decimal_to_float(runs_in_window(today.beginning_of_week, today).sum(:cost_usd)),
        month_usd: decimal_to_float(runs_in_window(today.beginning_of_month, today).sum(:cost_usd)),
        lifetime_usd: decimal_to_float(provider_scoped_runs.sum(:cost_usd) + provider_scoped_chat_sessions.sum(:cumulative_cost_usd)),
        workflow_lifetime_usd: decimal_to_float(provider_scoped_runs.sum(:cost_usd)),
        chat_lifetime_usd: decimal_to_float(provider_scoped_chat_sessions.sum(:cumulative_cost_usd)),
        average_job_30d_usd: average_cost_per_job(30.days.ago.to_date, today),
        average_merged_pr_30d_usd: average_cost_per_merged_pr(30.days.ago.to_date, today)
      }
    end

    def scoped_runs
      relation = Run.where.not(cost_usd: nil)
      relation = relation.joins(:job).where(jobs: { repository_id: repository_id }) if repository_id.present?
      relation = relation.joins(:job).where(jobs: { epic_id: epic_id }) if epic_id.present?
      return relation if user.admin?

      relation.where(user_id: user.id)
    end

    def scoped_jobs
      relation = Job.all
      relation = relation.where(repository_id: repository_id) if repository_id.present?
      relation = relation.where(epic_id: epic_id) if epic_id.present?
      return relation if user.admin?

      relation.where(user_id: user.id)
    end

    def scoped_chat_sessions
      return ChatSession.none if repository_id.present? || epic_id.present?

      relation = ChatSession.where.not(cumulative_cost_usd: nil)
      return relation if user.admin?

      relation.where(user_id: user.id)
    end

    def provider_scoped_runs
      return scoped_runs if agent_provider.blank?

      scoped_runs.where(agent_provider: agent_provider)
    end

    def provider_scoped_chat_sessions
      return scoped_chat_sessions if agent_provider.blank? || agent_provider == "claude"

      scoped_chat_sessions.none
    end

    def filtered_runs
      runs_in_window(start_date, end_date)
    end

    def runs_in_window(first_date, last_date)
      provider_scoped_runs.where(created_at: first_date.beginning_of_day..last_date.end_of_day)
    end

    def jobs_with_windowed_run_cost(first_date, last_date)
      scoped_jobs
        .joins(:runs)
        .where.not(runs: { cost_usd: nil })
        .where(runs: { created_at: first_date.beginning_of_day..last_date.end_of_day })
        .then { |relation| agent_provider.present? ? relation.where(runs: { agent_provider: agent_provider }) : relation }
    end

    def available_agent_providers
      @available_agent_providers ||= begin
        providers = scoped_runs.distinct.pluck(:agent_provider).compact
        providers << "claude" if scoped_chat_sessions.where("cumulative_cost_usd > 0").exists?
        User::AGENT_PROVIDERS.select { |provider| providers.include?(provider) }.map do |provider|
          { value: provider, label: App::Presentation.agent_provider_label(provider) }
        end
      end
    end

    def average_cost_per_job(first_date, last_date)
      rows = jobs_with_windowed_run_cost(first_date, last_date)
             .group("jobs.id")
             .sum("runs.cost_usd")
      return 0.0 if rows.empty?

      decimal_to_float(rows.values.sum.to_d / rows.size)
    end

    def average_cost_per_merged_pr(first_date, last_date)
      rows = jobs_with_windowed_run_cost(first_date, last_date)
             .where(closure_reason: Epic::MERGED_JOB_CLOSURE_REASONS)
             .group("jobs.id")
             .sum("runs.cost_usd")
      return 0.0 if rows.empty?

      decimal_to_float(rows.values.sum.to_d / rows.size)
    end

    def epic_breakdown
      rows = filtered_runs
             .joins(job: :epic)
             .group("epics.id", "epics.number", "epics.title")
             .pluck(
               "epics.id",
               "epics.number",
               "epics.title",
               Arel.sql("COUNT(DISTINCT jobs.id)"),
               Arel.sql("SUM(runs.cost_usd)")
             )

      rows.map do |id, number, title, jobs_count, total|
        breakdown_row(
          id: id,
          label: title,
          path: "/epics/#{id}",
          jobs_count: jobs_count,
          total: total,
          extra: { display_number: "EPIC-#{number}" }
        )
      end.sort_by { |row| -row[:total_usd] }
    end

    def user_breakdown
      rows = filtered_runs
             .joins(:user, :job)
             .group("users.id", "users.email_address", "users.name")
             .pluck(
               "users.id",
               "users.email_address",
               "users.name",
               Arel.sql("COUNT(DISTINCT jobs.id)"),
               Arel.sql("SUM(runs.cost_usd)")
             )
      last_30_by_user = runs_in_window(30.days.ago.to_date, today).group(:user_id).sum(:cost_usd)

      rows.map do |id, email, name, jobs_count, total|
        breakdown_row(
          id: id,
          label: name.presence || email,
          path: "/profiles/#{id}",
          jobs_count: jobs_count,
          total: total,
          extra: { last_30_days_usd: decimal_to_float(last_30_by_user[id] || 0) }
        )
      end.sort_by { |row| -row[:total_usd] }
    end

    def repository_breakdown
      rows = filtered_runs
             .joins(job: :repository)
             .group("repositories.id", "repositories.owner", "repositories.name")
             .pluck(
               "repositories.id",
               "repositories.owner",
               "repositories.name",
               Arel.sql("COUNT(DISTINCT jobs.id)"),
               Arel.sql("SUM(runs.cost_usd)")
             )

      rows.map do |id, owner, name, jobs_count, total|
        breakdown_row(
          id: id,
          label: "#{owner}/#{name}",
          path: "/repositories/#{id}",
          jobs_count: jobs_count,
          total: total
        )
      end.sort_by { |row| -row[:total_usd] }
    end

    def trigger_kind_breakdown
      rows = filtered_runs
             .group(:trigger_kind)
             .pluck(
               :trigger_kind,
               Arel.sql("COUNT(DISTINCT job_id)"),
               Arel.sql("COUNT(*)"),
               Arel.sql("SUM(cost_usd)")
             )

      rows.map do |trigger_kind, jobs_count, runs_count, total|
        total_float = decimal_to_float(total)
        {
          trigger_kind: trigger_kind,
          jobs_count: jobs_count,
          runs_count: runs_count,
          total_usd: total_float,
          average_usd: average(total_float, runs_count)
        }
      end.sort_by { |row| -row[:total_usd] }
    end

    def breakdown_row(id:, label:, path:, jobs_count:, total:, extra: {})
      total_float = decimal_to_float(total)
      {
        id: id,
        label: label,
        path: path,
        jobs_count: jobs_count,
        total_usd: total_float,
        average_job_usd: average(total_float, jobs_count)
      }.merge(extra)
    end

    def top_runs
      filtered_runs
        .includes(job: [ :repository, :epic ], step: :workflow)
        .order(cost_usd: :desc, created_at: :desc)
        .limit(TOP_RUN_LIMIT)
        .map do |run|
          job = run.job
          workflow = run.workflow
          {
            id: run.id,
            cost_usd: decimal_to_float(run.cost_usd),
            trigger_kind: run.trigger_kind,
            agent_provider: run.agent_provider,
            created_at: run.created_at.iso8601,
            job: {
              id: job.id,
              title: job.issue_title,
              path: workflow ? "/jobs/#{job.id}?tab=workflows#workflow-#{workflow.id}" : "/jobs/#{job.id}"
            },
            repository: {
              id: job.repository_id,
              slug: job.repository.slug,
              path: "/repositories/#{job.repository_id}"
            },
            epic: job.epic && {
              id: job.epic_id,
              display_number: job.epic.display_number,
              title: job.epic.title,
              path: "/epics/#{job.epic_id}"
            }
          }
        end
    end

    def trend
      range_start = [ start_date, end_date - (TREND_LIMIT_DAYS - 1).days ].max
      sums = runs_in_window(range_start, end_date)
             .group(date_bucket_sql)
             .sum(:cost_usd)

      (range_start..end_date).map do |date|
        {
          date: date.iso8601,
          total_usd: decimal_to_float(sums[date.to_s] || sums[date] || 0)
        }
      end
    end

    def date_bucket_sql
      adapter = ActiveRecord::Base.connection.adapter_name.downcase
      if adapter.include?("mysql")
        "DATE(runs.created_at)"
      else
        "date(runs.created_at)"
      end
    end

    def parse_date(value)
      return if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def parse_agent_provider(value)
      provider = value.to_s.presence
      return if provider.blank?
      return provider if User::AGENT_PROVIDERS.include?(provider) && available_agent_providers.any? { |option| option[:value] == provider }

      nil
    end

    def decimal_to_float(value)
      value.to_d.to_f
    end

    def average(total, count)
      return 0.0 if count.to_i.zero?

      (total.to_d / count.to_i).to_f
    end
  end
end
