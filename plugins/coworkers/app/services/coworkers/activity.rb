require "base64"

class Coworkers::Activity
  PAGE_SIZE = 50
  WORKFLOWS_PER_JOB_PAGE = 10
  FAILURE_STATES = %w[failed cancelled blocked].freeze
  SUCCESSFUL_CLOSURE_REASONS = Job::ClosureReason.successful_values
  class InvalidCursor < StandardError; end

  def self.weekly_spend_by_coworker(coworkers:, user:, now: Time.current)
    ids = coworkers.map(&:id)
    return {} if ids.empty?
    range = now.beginning_of_week..now
    chat = Syrus::Host::ActivityRecords.chat_spend_entries.joins("INNER JOIN coworker_chats ON coworker_chats.chat_session_id = chat_spend_entries.chat_session_id")
      .where(coworker_chats: { coworker_id: ids }, incurred_at: range).group("coworker_chats.coworker_id").sum(:cost_usd)
    visible = Syrus::Host::Jobs.visible_to(user).where(kind: "coworker_task", origin: "coworkers", origin_id: ids.map(&:to_s))
    run = Syrus::Host::Runs.joins(:job).where(job_id: visible.select(:id), finished_at: range).group("jobs.origin_id").sum(:cost_usd)
    ids.index_with { |id| (chat.fetch(id, 0).to_d + run.fetch(id.to_s, 0).to_d).to_f }
  end

  def initialize(coworker:, user:, now: Time.current, jobs_cursor: nil, side_chats_cursor: nil, filters: {})
    @coworker, @user, @now = coworker, user, now
    @jobs_cursor, @side_chats_cursor, @filters = jobs_cursor, side_chats_cursor, filters
  end

  def call
    job_page = page(filtered_jobs, @jobs_cursor)
    chat_page = page(side_chats, @side_chats_cursor)
    runs = Syrus::Host::Runs.where(job_id: job_page.map(&:id)).includes(:step).order(:created_at, :id).to_a
    counts = Syrus::Host::ActivityRecords.job_logs.where(run_id: runs.map(&:id), kind: "tool_call").group(:run_id).count
    workflows = Syrus::Host::Workflows.where(job_id: job_page.map(&:id)).order(:created_at, :id).to_a.group_by(&:job_id)
    names = schedule_names(job_page)
    {
      spend: spend_json,
      jobs: job_page.map { |job| job_json(job, runs.select { |run| run.job_id == job.id }, workflows.fetch(job.id, []), counts, names[job.scheduled_task_id]) },
      side_chats: chat_page.map { |chat| side_chat_json(chat) },
      next_cursors: { jobs: next_cursor(job_page), side_chats: next_cursor(chat_page) },
      filtered: @filters.values.any?(&:present?)
    }
  end

  def week_spend = self.class.weekly_spend_by_coworker(coworkers: [ @coworker ], user: @user, now: @now).fetch(@coworker.id)

  private

  def week_range = @now.beginning_of_week..@now
  def chat_ids = @chat_ids ||= @coworker.coworker_chats.select(:chat_session_id)
  def chats = Syrus::Host::ChatSessions.where(id: chat_ids)
  def side_chats = Syrus::Host::ChatSessions.where(id: @coworker.coworker_chats.where(role: "side").select(:chat_session_id))
  def jobs = @jobs ||= Syrus::Host::Jobs.visible_to(@user).where(kind: "coworker_task", origin: "coworkers", origin_id: @coworker.id.to_s)
  def all_runs = @all_runs ||= Syrus::Host::Runs.where(job_id: jobs.select(:id))

  def spend_json
    chat_entries = Syrus::Host::ActivityRecords.chat_spend_entries.where(chat_session_id: chat_ids)
    {
      week_usd: decimal(chat_entries.where(incurred_at: week_range).sum(:cost_usd) + all_runs.where(finished_at: week_range).sum(:cost_usd)),
      total_usd: decimal(chats.sum(:cumulative_cost_usd) + all_runs.sum(:cost_usd))
    }
  end

  def filtered_jobs
    relation = jobs
    relation = relation.where(state: @filters[:state].to_s.split(",")) if @filters[:state].present?
    relation = relation.where("jobs.created_at >= ?", Time.zone.parse(@filters[:created_after].to_s)) if @filters[:created_after].present?
    relation = relation.where("jobs.created_at <= ?", Time.zone.parse(@filters[:created_before].to_s).end_of_day) if @filters[:created_before].present?
    relation = relation.where(id: Syrus::Host::Workflows.where(trigger_kind: @filters[:source]).select(:job_id)) if @filters[:source].present?
    if @filters[:failures_only] == "true"
      unsuccessful = relation.where(state: FAILURE_STATES)
      closed = relation.where.not(closure_reason: [ nil, "", *SUCCESSFUL_CLOSURE_REASONS ])
      relation = unsuccessful.or(closed)
    end
    if @filters[:query].present?
      term = "%#{ActiveRecord::Base.sanitize_sql_like(@filters[:query].to_s)}%"
      relation = relation.where("jobs.issue_title LIKE :term OR jobs.issue_body LIKE :term", term: term)
    end
    relation
  rescue ArgumentError
    raise InvalidCursor, "invalid activity filter"
  end

  def page(relation, cursor)
    return [] if cursor == ""
    relation = relation.where("id < ?", decode_cursor(cursor)) if cursor.present?
    relation.order(id: :desc).limit(PAGE_SIZE).to_a
  end

  def next_cursor(records)
    Base64.urlsafe_encode64(records.last.id.to_s, padding: false) if records.size == PAGE_SIZE
  end

  def decode_cursor(cursor)
    Integer(Base64.urlsafe_decode64(cursor.to_s))
  rescue ArgumentError
    raise InvalidCursor, "invalid activity cursor"
  end

  def job_json(job, runs, workflows, counts, schedule_name)
    started = [ job.started_at, *runs.map(&:started_at) ].compact.min
    finished = job.finished_at || (runs.present? && runs.all?(&:finished_at?) ? runs.map(&:finished_at).max : nil)
    {
      id: job.id, slug: job.slug, title: job.title, goal_summary: Coworkers::JobGoalSummary.new(job).call,
      path: "/jobs/#{job.id}", state: job.state, source: workflows.last&.trigger_kind, schedule_name:,
      created_at: job.created_at.iso8601, started_at: started&.iso8601, finished_at: finished&.iso8601,
      duration_seconds: duration(started || job.created_at, finished), cost_usd: decimal(runs.sum { |run| run.cost_usd.to_d }),
      tool_calls_count: runs.sum { |run| counts.fetch(run.id, 0) }, outcome_reason: outcome_reason(job, workflows),
      attempts: workflows.each_with_index.map { |workflow, index| workflow_json(workflow, runs.select { |run| run.workflow_id == workflow.id }, counts, index:, total: workflows.size) }
    }
  end

  def workflow_json(workflow, runs, counts, index:, total:)
    page = ((total - index - 1) / WORKFLOWS_PER_JOB_PAGE) + 1
    query = { tab: "workflows" }
    query[:workflows_page] = page if page > 1
    path = "/jobs/#{workflow.job_id}?#{query.to_query}#workflow-#{workflow.id}"
    {
      id: workflow.id, slug: workflow.slug, path:, state: workflow.state,
      started_at: workflow.started_at&.iso8601, finished_at: workflow.finished_at&.iso8601,
      duration_seconds: duration(workflow.started_at || workflow.created_at, workflow.finished_at),
      failure_reason: workflow.failure_reason.to_s.truncate(300).presence,
      cost_usd: decimal(runs.sum { |run| run.cost_usd.to_d }), tool_calls_count: runs.sum { |run| counts.fetch(run.id, 0) },
      runs: runs.map { |run| run_json(run, counts, path:) }
    }
  end

  def run_json(run, counts, path:)
    {
      id: run.id, slug: run.slug, path:, state: run.state,
      started_at: run.started_at&.iso8601, finished_at: run.finished_at&.iso8601,
      duration_seconds: duration(run.started_at || run.created_at, run.finished_at),
      tool_calls_count: counts.fetch(run.id, 0), cost_usd: decimal(run.cost_usd)
    }
  end

  def duration(started, finished) = started && (((finished || @now) - started).round)

  def outcome_reason(job, workflows)
    unsuccessful_closure = job.closed? && !job.closure_reason.in?([ nil, "", *SUCCESSFUL_CLOSURE_REASONS ])
    return unless job.failed? || unsuccessful_closure

    reason = job.landing_failure_reason.presence || workflows.reverse.find { |workflow| workflow.failure_reason.present? }&.failure_reason || job.closure_reason
    reason.to_s.tr("_", " ").truncate(300).presence
  end

  def schedule_names(records)
    ids = records.filter_map(&:scheduled_task_id).uniq
    return {} if ids.empty? || !defined?(ScheduledTasks::Task)
    ScheduledTasks::Task.where(id: ids).pluck(:id, :name).to_h
  end

  def side_chat_json(chat) = { id: chat.id, title: chat.title, path: "/chats/#{chat.id}", cost_usd: decimal(chat.cumulative_cost_usd) }
  def decimal(value) = value.to_d.to_f
end
