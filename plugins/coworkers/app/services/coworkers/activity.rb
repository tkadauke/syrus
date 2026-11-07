require "base64"

class Coworkers::Activity
  PAGE_SIZE = 50
  class InvalidCursor < StandardError; end

  def self.weekly_spend_by_coworker(coworkers:, user:, now: Time.current)
    coworker_ids = coworkers.map(&:id)
    return {} if coworker_ids.empty?

    week_range = now.beginning_of_week..now
    chat_spend = ChatSpendEntry
      .joins("INNER JOIN coworker_chats ON coworker_chats.chat_session_id = chat_spend_entries.chat_session_id")
      .where(coworker_chats: { coworker_id: coworker_ids }, incurred_at: week_range)
      .group("coworker_chats.coworker_id")
      .sum(:cost_usd)
    visible_jobs = Job.visible_to(user).where(
      kind: "coworker_task", origin: "coworkers", origin_id: coworker_ids.map(&:to_s)
    )
    run_spend = Run.joins(:job)
      .where(job_id: visible_jobs.select(:id), finished_at: week_range)
      .group("jobs.origin_id")
      .sum(:cost_usd)

    coworker_ids.index_with do |coworker_id|
      chat_spend.fetch(coworker_id, 0).to_d + run_spend.fetch(coworker_id.to_s, 0).to_d
    end.transform_values(&:to_f)
  end

  def initialize(coworker:, user:, now: Time.current, runs_cursor: nil, side_chats_cursor: nil)
    @coworker = coworker
    @user = user
    @now = now
    @runs_cursor = runs_cursor
    @side_chats_cursor = side_chats_cursor
  end

  def call
    ordered_runs = page(runs, @runs_cursor)
    ordered_side_chats = page(side_chats, @side_chats_cursor)
    tool_call_counts = JobLog.where(run_id: ordered_runs.map(&:id), kind: "tool_call").group(:run_id).count

    {
      spend: {
        week_usd: decimal_to_float(chat_spend_entries.where(incurred_at: week_range).sum(:cost_usd) + runs.where(finished_at: week_range).sum(:cost_usd)),
        total_usd: decimal_to_float(chats.sum(:cumulative_cost_usd) + runs.sum(:cost_usd))
      },
      runs: ordered_runs.map { |run| run_json(run, tool_call_counts) },
      side_chats: ordered_side_chats.map { |chat| side_chat_json(chat) },
      next_cursors: {
        runs: next_cursor(ordered_runs),
        side_chats: next_cursor(ordered_side_chats)
      }
    }
  end

  def week_spend
    self.class.weekly_spend_by_coworker(coworkers: [ coworker ], user: user, now: now).fetch(coworker.id)
  end

  private

  attr_reader :coworker, :user, :now

  def week_range = now.beginning_of_week..now

  def chat_ids
    @chat_ids ||= coworker.coworker_chats.select(:chat_session_id)
  end

  def chats
    ChatSession.where(id: chat_ids)
  end

  def side_chats
    side_ids = coworker.coworker_chats.where(role: "side").select(:chat_session_id)
    ChatSession.where(id: side_ids)
  end

  def page(relation, cursor)
    return [] if cursor == ""

    relation = relation.where("id < ?", decode_cursor(cursor)) if cursor.present?
    relation.order(id: :desc).limit(PAGE_SIZE).to_a
  end

  def next_cursor(records)
    return unless records.size == PAGE_SIZE

    Base64.urlsafe_encode64(records.last.id.to_s, padding: false)
  end

  def decode_cursor(cursor)
    Integer(Base64.urlsafe_decode64(cursor.to_s))
  rescue ArgumentError
    raise InvalidCursor, "invalid activity cursor"
  end

  def chat_spend_entries
    ChatSpendEntry.where(chat_session_id: chat_ids)
  end

  def jobs
    @jobs ||= Job.visible_to(user)
      .where(kind: "coworker_task", origin: "coworkers", origin_id: coworker.id.to_s)
  end

  def runs
    @runs ||= Run.where(job_id: jobs.select(:id))
  end

  def run_json(run, tool_call_counts)
    {
      id: run.id,
      job_id: run.job_id,
      state: run.state,
      started_at: run.started_at&.iso8601,
      finished_at: run.finished_at&.iso8601,
      tool_calls_count: tool_call_counts.fetch(run.id, 0),
      cost_usd: decimal_to_float(run.cost_usd)
    }
  end

  def side_chat_json(chat)
    {
      id: chat.id,
      title: chat.title,
      path: "/chats/#{chat.id}",
      cost_usd: decimal_to_float(chat.cumulative_cost_usd)
    }
  end

  def decimal_to_float(value)
    value.to_d.to_f
  end
end
