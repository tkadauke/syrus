module App
  class SpendingPayload
    DEFAULT_WINDOW_DAYS = App::SpendingFilter::DEFAULT_WINDOW_DAYS
    TOP_RUN_LIMIT = 10
    TREND_LIMIT_DAYS = 370

    def initialize(user:, params: {})
      @user = user
      @params = params
      @today = Time.zone.today
      @filter = App::SpendingFilter.from_params(params, user: user)
      @start_date = @filter.start_date
      @end_date = @filter.end_date
    end

    def as_json(*)
      PerformanceLogging.phase("spending_payload", admin: user.admin?) do
        {
          scope: scope_json,
          filter: filter.to_h,
          filters: filters_json,
          controls: controls_json,
          totals: PerformanceLogging.phase("spending.totals") { totals_json },
          breakdowns: {
            epics: PerformanceLogging.phase("spending.breakdown.epics") { epic_breakdown },
            users: PerformanceLogging.phase("spending.breakdown.users") { user_breakdown },
            repositories: PerformanceLogging.phase("spending.breakdown.repositories") { repository_breakdown },
            trigger_kinds: PerformanceLogging.phase("spending.breakdown.trigger_kinds") { trigger_kind_breakdown }
          },
          top_runs: PerformanceLogging.phase("spending.top_runs") { top_runs },
          trend: PerformanceLogging.phase("spending.trend") { trend }
        }
      end
    end

    private

    attr_reader :user, :start_date, :end_date, :today, :filter

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
        agent_provider: filter_value("agent_provider"),
        repository_id: filter_value("repository_id")&.to_i,
        epic_id: filter_value("epic_id")&.to_i,
        user_id: filter_value("user_id")&.to_i,
        trigger_kind: filter_value("trigger_kind"),
        agent_providers: available_agent_providers
      }
    end

    def controls_json
      {
        filter_schema: Filters::Schema.for(subject: :spending_report, user: user)
      }
    end

    def totals_json
      run_totals = run_cost_totals
      chat_lifetime_usd = chat_lifetime_cost

      {
        week_usd: decimal_to_float(run_totals.fetch(:week)),
        month_usd: decimal_to_float(run_totals.fetch(:month)),
        lifetime_usd: decimal_to_float(run_totals.fetch(:lifetime) + chat_lifetime_usd),
        workflow_lifetime_usd: decimal_to_float(run_totals.fetch(:lifetime)),
        chat_lifetime_usd: decimal_to_float(chat_lifetime_usd),
        average_job_30d_usd: average_cost_per_job(30.days.ago.to_date, today),
        average_merged_pr_30d_usd: average_cost_per_merged_pr(30.days.ago.to_date, today)
      }
    end

    def run_cost_totals
      @run_cost_totals ||= begin
        week, month, lifetime = filtered_runs.pick(
          Arel.sql(cost_sum_between_sql(today.beginning_of_week.beginning_of_day, today.end_of_day)),
          Arel.sql(cost_sum_between_sql(today.beginning_of_month.beginning_of_day, today.end_of_day)),
          Arel.sql("COALESCE(SUM(runs.cost_usd), 0)")
        )

        { week: week || 0, month: month || 0, lifetime: lifetime || 0 }
      end
    end

    def chat_lifetime_cost
      @chat_lifetime_cost ||= provider_scoped_chat_sessions.sum(:cumulative_cost_usd)
    end

    def scoped_runs
      relation = Run.where.not(cost_usd: nil)
      relation = relation.where(user_id: user.id) unless user.admin?

      filter.apply(relation)
    end

    def scoped_jobs
      Job.where(id: filtered_runs.select(:job_id))
    end

    def scoped_chat_sessions
      return ChatSession.none if run_only_filter?

      relation = ChatSession.where.not(cumulative_cost_usd: nil)
      relation = relation.where(created_at: start_date.beginning_of_day..end_date.end_of_day)
      relation = relation.where(user_id: filter_value("user_id")) if user.admin? && filter_value("user_id").present?
      return relation if user.admin?

      relation.where(user_id: user.id)
    end

    def provider_scoped_runs
      scoped_runs
    end

    def provider_scoped_chat_sessions
      provider = filter_value("agent_provider")
      return scoped_chat_sessions if provider.blank? || provider == "claude"

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
        .where(runs: { id: filtered_runs.select(:id) })
        .where(runs: { created_at: first_date.beginning_of_day..last_date.end_of_day })
    end

    def available_agent_providers
      @available_agent_providers ||= begin
        providers = base_accessible_runs.distinct.pluck(:agent_provider).compact
        providers << "claude" if scoped_chat_sessions.where("cumulative_cost_usd > 0").exists?
        User.agent_providers.select { |provider| providers.include?(provider) }.map do |provider|
          { value: provider, label: App::Presentation.agent_provider_label(provider) }
        end
      end
    end

    def average_cost_per_job(first_date, last_date)
      total, count = grouped_job_cost_total_and_count(jobs_with_windowed_run_cost(first_date, last_date))
      return 0.0 if count.zero?

      decimal_to_float(total.to_d / count)
    end

    def average_cost_per_merged_pr(first_date, last_date)
      total, count = grouped_job_cost_total_and_count(
        jobs_with_windowed_run_cost(first_date, last_date)
          .where(closure_reason: Epic::MERGED_JOB_CLOSURE_REASONS)
      )
      return 0.0 if count.zero?

      decimal_to_float(total.to_d / count)
    end

    def grouped_job_cost_total_and_count(relation)
      grouped_sql = relation
        .group("jobs.id")
        .select("jobs.id, SUM(runs.cost_usd) AS job_cost")
        .to_sql
      row = ActiveRecord::Base.connection.select_one(<<~SQL.squish)
        SELECT COALESCE(SUM(job_cost), 0) AS total_cost, COUNT(*) AS job_count
        FROM (#{grouped_sql}) spending_job_costs
      SQL

      [ row.fetch("total_cost") || 0, row.fetch("job_count").to_i ]
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
          extra: { display_number: App::Presentation.epic_slug(number) }
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
              display_number: job.epic.slug,
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

    def cost_sum_between_sql(first_time, last_time)
      connection = ActiveRecord::Base.connection
      start_sql = connection.quote(first_time)
      end_sql = connection.quote(last_time)
      "COALESCE(SUM(CASE WHEN runs.created_at BETWEEN #{start_sql} AND #{end_sql} THEN runs.cost_usd ELSE 0 END), 0)"
    end

    def parse_date(value)
      return if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def base_accessible_runs
      relation = Run.where.not(cost_usd: nil)
      return relation if user.admin?

      relation.where(user_id: user.id)
    end

    def filter_value(field)
      filter.exact_value(field)
    end

    def run_only_filter?
      (filter_fields - %w[created_at agent_provider user_id]).any?
    end

    def filter_fields
      filter.fields
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
