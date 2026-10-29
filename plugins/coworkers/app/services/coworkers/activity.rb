class Coworkers::Activity
  def initialize(coworker:, user:, now: Time.current)
    @coworker = coworker
    @user = user
    @now = now
  end

  def call
    {
      spend: {
        week_usd: decimal_to_float(chat_spend_entries.where(incurred_at: week_range).sum(:cost_usd) + runs.where(finished_at: week_range).sum(:cost_usd)),
        total_usd: decimal_to_float(chats.sum(:cumulative_cost_usd) + runs.sum(:cost_usd))
      },
      runs: runs.order(created_at: :desc, id: :desc).map { |run| run_json(run) },
      side_chats: side_chats.map { |chat| side_chat_json(chat) }
    }
  end

  def week_spend
    decimal_to_float(chat_spend_entries.where(incurred_at: week_range).sum(:cost_usd) + runs.where(finished_at: week_range).sum(:cost_usd))
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
      .order(last_message_at: :desc, id: :desc)
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

  def run_json(run)
    {
      id: run.id,
      job_id: run.job_id,
      state: run.state,
      started_at: run.started_at&.iso8601,
      finished_at: run.finished_at&.iso8601,
      tool_calls_count: run.job_logs.where(kind: "tool_call").count,
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
