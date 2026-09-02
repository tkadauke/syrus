require "zlib"

class ChatQueuedMessagePromoter
  def self.deliver_one_if_idle!(chat_session)
    new(chat_session).deliver_one_if_idle!
  end

  def initialize(chat_session)
    @chat_session = chat_session
  end

  def deliver_one_if_idle!
    user_message = nil
    turn_triggered = false

    ApplicationRecord.transaction do
      chat = ChatSession.lock.find(@chat_session.id)
      return false if chat.stop_requested_at?
      return false if chat.turn_in_flight?
      return false if chat.agent_busy?

      queued_message = chat.queued_messages.first
      return false unless queued_message
      return false unless goal_continuation_ready?(chat, queued_message)

      promoted_role = queued_message.promoted_role
      turn_triggered = turn_triggered?(chat, queued_message)
      user_message = chat.messages.create!(
        role: promoted_role,
        content: queued_message.promoted_content,
        skip_turn_trigger: promoted_role == "user" && !turn_triggered
      )
      queued_message.update!(delivered_at: Time.current)
      chat.update!(
        last_message_at: Time.current,
        title: chat.title.presence,
        turn_in_flight: turn_triggered
      )
      chat.pin_chat_provider!
    end

    ChatTurnJob.perform_later(@chat_session.id, user_message.id) if turn_triggered
    true
  end

  private

  def turn_triggered?(chat, queued_message)
    return true if queued_message.promoted_role == "system"

    chat.should_trigger_agent?(queued_message.text)
  end

  def goal_continuation_ready?(chat, queued_message)
    content = queued_message.content
    return true unless content.is_a?(Hash) && content["goal_continuation"] == true

    goal = goal_for(chat, content)
    return true unless goal&.require_ready_coding_checkout_for_continuation?

    repository = goal.repository || chat.repository
    unless repository
      record_readiness_event!(chat, goal, nil, "repository missing")
      return false
    end

    snapshot = ChatWorkspace.coding_checkout_snapshot(chat, repository)
    return true if snapshot[:exists] && snapshot[:prepare_status] == "succeeded"

    record_readiness_event!(chat, goal, snapshot, readiness_reason(snapshot))
    false
  end

  def goal_for(chat, content)
    chat.chat_goals.find_by(id: content["chat_goal_id"]) || chat.active_goal
  end

  def readiness_reason(snapshot)
    return "checkout missing" unless snapshot && snapshot[:exists]

    status = snapshot[:prepare_status].presence || "unknown"
    return "checkout prepare failed: #{snapshot[:prepare_failure]}" if status == "failed" && snapshot[:prepare_failure].present?

    "checkout prepare #{status}"
  end

  def record_readiness_event!(chat, goal, snapshot, reason)
    ChatScopedEvent.record!(
      chat_session: chat,
      source_kind: "goal_coding_checkout_readiness",
      repository: goal.repository || chat.repository,
      payload: {
        "kind" => "goal_coding_checkout_readiness",
        "severity" => snapshot && snapshot[:prepare_status] == "failed" ? "warning" : "info",
        "subject" => "Coding checkout not ready",
        "summary" => "Goal continuation is waiting because the coding checkout is not ready: #{reason}.",
        "goal" => {
          "id" => goal.id,
          "mode_snapshot" => goal.mode_snapshot,
          "auto_submit_jobs" => goal.auto_submit_jobs?
        },
        "work_state" => {
          "state" => snapshot && snapshot[:prepare_status] == "failed" ? "blocked" : "waiting",
          "reason" => reason,
          "checkout_exists" => snapshot && snapshot[:exists],
          "prepare_status" => snapshot && snapshot[:prepare_status]
        },
        "occurred_at" => Time.current.iso8601
      },
      dedupe_key: readiness_dedupe_key(goal, snapshot, reason)
    )
  end

  def readiness_dedupe_key(goal, snapshot, reason)
    status = snapshot && snapshot[:prepare_status]
    exists = snapshot && snapshot[:exists]
    "goal:#{goal.id}:coding_checkout_readiness:#{exists}:#{status}:#{Zlib.crc32(reason.to_s)}"
  end
end
