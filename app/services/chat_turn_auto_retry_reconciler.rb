class ChatTurnAutoRetryReconciler
  GRACE_PERIOD = 75.seconds
  FAILED_MESSAGE = ChatStopReconciler::FAILED_MESSAGE

  def self.sweep!(stale_before: GRACE_PERIOD.ago, now: Time.current)
    new(stale_before: stale_before, now: now).sweep!
  end

  def self.reconcile_spawned_process!(spawned_process, finished_at: Time.current)
    new(stale_before: GRACE_PERIOD.ago, now: finished_at).send(
      :reconcile_spawned_process!,
      spawned_process,
      finished_at: finished_at
    )
  end

  def initialize(stale_before:, now:)
    @stale_before = stale_before
    @now = now
  end

  def sweep!
    performed = perform_due_retries!
    scheduled_or_exhausted = schedule_or_exhaust_crashed_turns!
    performed + scheduled_or_exhausted
  end

  private

  attr_reader :stale_before, :now

  def perform_due_retries!
    count = 0

    ChatTurnAutoRetryAttempt.due(now).find_each do |attempt|
      count += 1 if perform_attempt!(attempt)
    end

    count
  end

  def schedule_or_exhaust_crashed_turns!
    count = 0

    candidate_sessions.find_each do |chat|
      count += 1 if reconcile_crashed_turn!(chat)
    end

    count
  end

  def candidate_sessions
    ChatSession
      .where(turn_in_flight: true)
      .where("last_message_at < ? OR last_message_at IS NULL", stale_before)
  end

  def reconcile_spawned_process!(spawned_process, finished_at:)
    return false unless spawned_process&.kind == "agent"
    return false if spawned_process.workdir.blank?

    chat = ChatTurnLiveness.chat_session_for_workdir(spawned_process.workdir)
    return false unless chat
    return false if stop_request_should_use_terminal_path?(chat, spawned_process, finished_at)
    return true unless spawned_process_failed?(spawned_process)
    return true if newer_turn_than_spawned_process?(chat, spawned_process)
    return true unless chat.turn_in_flight?

    reconcile_crashed_turn!(chat, require_stale: false)
    true
  end

  def reconcile_crashed_turn!(chat_session, require_stale: true)
    changed = false

    ApplicationRecord.transaction do
      chat = ChatSession.lock.find(chat_session.id)
      next false unless confirmed_dead_turn?(chat, require_stale: require_stale)

      latest_user_message = ChatTurnLiveness.new(chat).latest_user_message
      next false unless latest_user_message

      root_message = root_user_message_for(latest_user_message)
      next false if exhausted?(chat, root_message)
      next false if pending_attempt?(chat, root_message)

      attempts_used = attempts_for(chat, root_message).unskipped.count
      if attempts_used >= ChatTurnAutoRetryAttempt::MAX_ATTEMPTS
        exhaust_budget!(chat, root_message)
      else
        create_attempt!(chat, root_message, latest_user_message, attempts_used + 1)
      end
      changed = true
    end

    broadcast(chat_session) if changed
    changed
  end

  def confirmed_dead_turn?(chat, require_stale:)
    return false unless chat.turn_in_flight?

    liveness = ChatTurnLiveness.new(chat)
    latest_user_message = liveness.latest_user_message
    return false unless latest_user_message
    return false if require_stale && latest_user_message.created_at >= stale_before
    return false if liveness.live_agent_process?
    return false if liveness.pending_chat_turn_job?

    true
  end

  def stop_request_should_use_terminal_path?(chat, spawned_process, finished_at)
    return false unless chat.stop_requested_at
    return false if finished_at && chat.stop_requested_at > finished_at
    return false if newer_turn_than_spawned_process?(chat, spawned_process)

    true
  end

  def spawned_process_failed?(spawned_process)
    ChatStopReconciler::FAILED_PROCESS_OUTCOMES.include?(spawned_process.reload.outcome)
  rescue ActiveRecord::RecordNotFound
    false
  end

  def newer_turn_than_spawned_process?(chat, spawned_process)
    latest_user_message = ChatTurnLiveness.new(chat).latest_user_message
    return false unless latest_user_message

    latest_user_message.created_at > spawned_process.started_at
  end

  def pending_attempt?(chat, root_message)
    attempts_for(chat, root_message).active.where(performed_at: nil).exists?
  end

  def exhausted?(chat, root_message)
    attempts_for(chat, root_message).where.not(exhausted_at: nil).exists?
  end

  def attempts_for(chat, root_message)
    chat.turn_auto_retry_attempts.where(root_user_message: root_message)
  end

  def root_user_message_for(message)
    ChatTurnAutoRetryAttempt.find_by(retry_message: message)&.root_user_message || message
  end

  def create_attempt!(chat, root_message, user_message, attempt_number)
    chat.turn_auto_retry_attempts.create!(
      root_user_message: root_message,
      user_message: user_message,
      attempt_number: attempt_number,
      scheduled_at: now + ChatTurnAutoRetryAttempt.backoff_for(attempt_number)
    )
  end

  def exhaust_budget!(chat, root_message)
    attempts_for(chat, root_message)
      .unskipped
      .order(:attempt_number, :id)
      .last
      &.update!(exhausted_at: now)
    close_dangling_tool_calls!(chat)
    chat.messages.create!(role: "system", content: { "text" => FAILED_MESSAGE })
    chat.update!(turn_in_flight: false, stop_requested_at: nil, last_message_at: now)
  end

  def perform_attempt!(attempt)
    chat = nil
    retry_message = nil

    ApplicationRecord.transaction do
      locked_attempt = ChatTurnAutoRetryAttempt.lock.find(attempt.id)
      next false if locked_attempt.performed_at? || locked_attempt.skipped_reason? || locked_attempt.exhausted_at?
      next false if locked_attempt.scheduled_at > now

      chat = ChatSession.lock.find(locked_attempt.chat_session_id)
      unless chat.turn_in_flight?
        locked_attempt.update!(skipped_reason: "chat turn is no longer in flight")
        next false
      end

      latest_user_message = ChatTurnLiveness.new(chat).latest_user_message
      unless latest_user_message&.id == locked_attempt.user_message_id
        locked_attempt.update!(skipped_reason: "chat turn moved to a newer user message")
        next false
      end

      liveness = ChatTurnLiveness.new(chat)
      if liveness.live_agent_process? || liveness.pending_chat_turn_job?
        locked_attempt.update!(skipped_reason: "chat turn became active before retry")
        next false
      end

      retry_message = chat.messages.create!(
        role: "user",
        content: locked_attempt.user_message.content.deep_dup,
        sender_user_id: locked_attempt.user_message.sender_user_id,
        skip_turn_trigger: false
      )
      chat.update!(
        last_message_at: now,
        title: chat.title.presence,
        turn_in_flight: true
      )
      chat.pin_chat_provider!
      ChatTurnJob.perform_later(chat.id, retry_message.id)
      locked_attempt.update!(performed_at: now, retry_message: retry_message)
    end

    broadcast(chat) if chat
    retry_message.present?
  end

  def close_dangling_tool_calls!(chat)
    ChatDanglingToolCallCloser.close!(
      chat_session: chat,
      message: "#{FAILED_MESSAGE.delete_suffix(".")} before this tool returned."
    )
  end

  def broadcast(chat)
    chat.reload
    chat.broadcast_controls
    chat.broadcast_app_header_update
    ChatQueuedMessagePromoter.deliver_one_if_idle!(chat)
  end
end
