class Coworkers::SpawnChatLimiter
  ACTIVE_STATES = %w[queued pending confirming confirmed].freeze

  def initialize(coworker:, server_context:, now: Time.current)
    @coworker = coworker
    @server_context = server_context
    @now = now
  end

  def allowed?
    refusal.nil?
  end

  def refusal
    return "Side-chat spawn cap reached: at most #{per_run_cap} per run." if run_actions.size >= per_run_cap
    return "Side-chat spawn cap reached: at most #{per_day_cap} per day." if daily_actions.size >= per_day_cap
  end

  private

  def grant = @coworker.grants.find_by!(capability: "coworker.spawn_chat")
  def per_run_cap = positive_constraint("max_spawns_per_run", Coworkers::SpawnChatTool::DEFAULT_PER_RUN_CAP)
  def per_day_cap = positive_constraint("max_spawns_per_day", Coworkers::SpawnChatTool::DEFAULT_PER_DAY_CAP)

  def positive_constraint(key, fallback)
    value = Integer(grant.constraints.to_h[key], exception: false)
    value&.positive? ? value : fallback
  end

  def daily_actions
    @daily_actions ||= ChatPendingAction.where(chat_session_id: @coworker.coworker_chats.select(:chat_session_id),
      action: "coworker_tool_call", state: ACTIVE_STATES, created_at: @now.beginning_of_day..@now.end_of_day)
      .select do |action|
        action.id != @server_context[:pending_action_id] && action.payload["tool_name"] == Coworkers::SpawnChatTool.tool_name
      end
  end

  def run_actions
    run_id = @server_context[:run]&.id || @server_context[:run_id]
    message_id = @server_context[:current_message]&.id
    daily_actions.select do |action|
      run_id.present? ? action.payload["run_id"] == run_id : action.payload["origin_message_id"] == message_id
    end
  end
end
