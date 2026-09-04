class ChatStopReconciler
  CANCELLED_MESSAGE = "Cancelled by operator."
  FAILED_MESSAGE = "Agent turn failed."
  TERMINAL_MESSAGE = CANCELLED_MESSAGE
  FAILED_PROCESS_OUTCOMES = (SpawnedProcess::OUTCOMES - [ "succeeded" ]).freeze
  STALE_TURN_THRESHOLD = AgentInvocation::DEFAULT_TIMEOUT_SECONDS.seconds + 30.minutes

  def self.reconcile!(...)
    new(...).reconcile!
  end

  def self.reconcile_stale_turns!(stale_before: STALE_TURN_THRESHOLD.ago)
    reconciled = 0

    stale_turn_candidate_sessions(stale_before).find_each do |chat|
      reconciled += 1 if reconcile!(chat_session: chat, stale_before: stale_before)
    end

    reconciled
  end

  def self.reconcile_spawned_process!(spawned_process, finished_at: Time.current)
    return false unless spawned_process&.kind == "agent"
    return false if spawned_process.workdir.blank?

    chat = chat_session_for_workdir(spawned_process.workdir)
    return false unless chat

    reconcile!(
      chat_session: chat,
      spawned_process: spawned_process,
      stop_requested_before: finished_at
    )
  end

  def self.chat_session_for_workdir(workdir)
    ChatSession.find_by(workspace_path: workdir) || chat_session_from_default_workdir(workdir)
  end

  def self.chat_session_from_default_workdir(workdir)
    path = Pathname.new(workdir.to_s)
    return unless path.basename.to_s.match?(/\A\d+\z/)
    return unless path.dirname.basename.to_s == "chat-workspaces"

    ChatSession.find_by(id: path.basename.to_s)
  end

  def self.stale_turn_candidate_sessions(stale_before)
    ChatSession
      .where(turn_in_flight: true)
      .where("last_message_at < ? OR last_message_at IS NULL", stale_before)
  end
  private_class_method :chat_session_for_workdir, :chat_session_from_default_workdir, :stale_turn_candidate_sessions

  def initialize(chat_session:, spawned_process: nil, stop_requested_before: nil, stale_before: nil, message: TERMINAL_MESSAGE)
    @chat_session = chat_session
    @spawned_process = spawned_process
    @stop_requested_before = stop_requested_before
    @stale_before = stale_before
    @message = message
  end

  def reconcile!
    changed = false

    ApplicationRecord.transaction do
      chat = ChatSession.lock.find(@chat_session.id)
      stop_request = reconcile_stop_request?(chat)
      orphaned_turn = reconcile_orphaned_turn?(chat)
      stale_turn = reconcile_stale_turn?(chat)
      return false unless stop_request || orphaned_turn || stale_turn
      return false if live_agent_process?(chat)
      return false if stale_turn && pending_chat_turn_job?(chat)

      turn_in_flight = chat.turn_in_flight?
      message = stop_request ? @message : FAILED_MESSAGE
      closed_tool_calls = close_dangling_tool_calls!(chat, message)
      if turn_in_flight || closed_tool_calls.positive?
        create_terminal_message!(chat, message)
      end
      chat.update!(stop_requested_at: nil) if chat.stop_requested_at?
      changed = true
    end

    @chat_session.reload
    @chat_session.broadcast_controls
    @chat_session.broadcast_app_header_update
    ChatQueuedMessagePromoter.deliver_one_if_idle!(@chat_session)
    changed
  end

  private

  def reconcile_stop_request?(chat)
    return false unless chat.stop_requested_at
    return false if @stop_requested_before && chat.stop_requested_at > @stop_requested_before
    return false if newer_turn_than_spawned_process?(chat)

    true
  end

  def reconcile_orphaned_turn?(chat)
    return false unless spawned_process_failed?
    return false if newer_turn_than_spawned_process?(chat)

    chat.turn_in_flight? || dangling_tool_calls_after_latest_user?(chat)
  end

  def reconcile_stale_turn?(chat)
    return false unless @stale_before

    latest_user_message = latest_user_message(chat)
    return false unless latest_user_message
    return false unless latest_user_message.created_at < @stale_before

    chat.turn_in_flight?
  end

  def spawned_process_failed?
    return false unless @spawned_process

    FAILED_PROCESS_OUTCOMES.include?(@spawned_process.reload.outcome)
  rescue ActiveRecord::RecordNotFound
    false
  end

  def newer_turn_than_spawned_process?(chat)
    return false unless @spawned_process

    latest_user_message = latest_user_message(chat)
    return false unless latest_user_message

    latest_user_message.created_at > @spawned_process.started_at
  end

  def latest_user_message(chat)
    chat.messages.where(role: "user").order(:created_at, :id).last
  end

  def dangling_tool_calls_after_latest_user?(chat)
    latest_user_message = latest_user_message(chat)
    return false unless latest_user_message

    messages_after_latest_user = chat.messages.where(
      "created_at > ? OR (created_at = ? AND id > ?)",
      latest_user_message.created_at,
      latest_user_message.created_at,
      latest_user_message.id
    )
    tool_use_ids = messages_after_latest_user.where(role: "tool_use").pluck(:tool_use_id).compact_blank
    return false if tool_use_ids.empty?

    answered_ids = messages_after_latest_user
      .where(role: "tool_result", tool_use_id: tool_use_ids)
      .pluck(:tool_use_id)
    (tool_use_ids - answered_ids).any?
  end

  def live_agent_process?(chat)
    SpawnedProcess.live_agent
                  .where(workdir: chat.workspace_root.to_s)
                  .exists?
  end

  def pending_chat_turn_job?(chat)
    latest_user_message = latest_user_message(chat)
    return false unless latest_user_message

    active_chat_turn_job_arguments.any? do |arguments|
      chat_turn_job_for_message?(arguments, chat.id, latest_user_message.id)
    end
  end

  def active_chat_turn_job_arguments
    [
      SolidQueue::ReadyExecution,
      SolidQueue::ClaimedExecution,
      SolidQueue::BlockedExecution
    ].flat_map do |execution_class|
      execution_class
        .joins(:job)
        .where(solid_queue_jobs: { class_name: "ChatTurnJob", finished_at: nil })
        .pluck("solid_queue_jobs.arguments")
    rescue ActiveRecord::StatementInvalid
      []
    end
  rescue NameError
    []
  end

  def chat_turn_job_for_message?(arguments, chat_id, message_id)
    values = job_argument_values(arguments)
    return false if values.length < 2

    values[0].to_i == chat_id.to_i && values[1].to_i == message_id.to_i
  end

  def job_argument_values(arguments)
    payload = if arguments.respond_to?(:dig)
      arguments
    else
      JSON.parse(arguments.to_s)
    end

    Array(payload&.dig("arguments") || payload&.dig(:arguments))
  rescue JSON::ParserError
    []
  end

  def create_terminal_message!(chat, message)
    chat.messages.create!(role: "system", content: { "text" => message })
  end

  def close_dangling_tool_calls!(chat, message)
    ChatDanglingToolCallCloser.close!(
      chat_session: chat,
      message: "#{message.delete_suffix(".")} before this tool returned."
    )
  end
end
