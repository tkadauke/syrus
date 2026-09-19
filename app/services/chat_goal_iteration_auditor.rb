class ChatGoalIterationAuditor
  def self.after_turn!(chat_session:, user_message:)
    new(chat_session: chat_session, user_message: user_message).after_turn!
  end

  def initialize(chat_session:, user_message:)
    @chat_session = chat_session
    @user_message = user_message
  end

  def after_turn!
    goal_continuation_contents.each { |content| audit_goal_continuation!(content) }
  end

  private

  def audit_goal_continuation!(content)
    goal = ChatGoal.find_by(id: content["chat_goal_id"])
    return unless goal&.active?

    signature = work_signature(goal)
    return goal.record_progress!(signature: signature) if new_goal_work_since_turn?(goal)

    count = goal.record_no_op_iteration!(signature: signature)
    return if count < ChatGoal::MAX_CONSECUTIVE_NO_OP_ITERATIONS

    goal.block!(
      reason: "max_consecutive_no_op_iterations",
      details: {
        "iterations" => count,
        "signature" => signature,
        "message_id" => @user_message.id
      }
    )
    @chat_session.messages.create!(
      role: "system",
      content: {
        "text" => "Goal blocked after #{count} continuation turns made no provenance-linked progress.",
        "source" => "goal_loop",
        "chat_goal_id" => goal.id
      }
    )
  end

  def goal_continuation_contents
    content = @user_message&.content
    return [] unless content.is_a?(Hash)
    return [ content ] if goal_continuation_content?(content)

    Array(content["notices"]).filter_map do |notice|
      notice_content = notice.is_a?(Hash) ? notice["content"] : nil
      notice_content if goal_continuation_content?(notice_content)
    end
  end

  def goal_continuation_content?(content)
    content.is_a?(Hash) && content["goal_continuation"] == true
  end

  def new_goal_work_since_turn?(goal)
    since = @user_message.created_at || Time.current
    @chat_session.proposals.where(chat_goal_id: goal.id).where("created_at > ?", since).exists? ||
      Job.where(chat_goal_id: goal.id).where("created_at > ? OR updated_at > ?", since, since).exists? ||
      Epic.where(chat_goal_id: goal.id).where("created_at > ? OR updated_at > ?", since, since).exists?
  end

  def work_signature(goal)
    [
      @chat_session.proposals.where(chat_goal_id: goal.id).maximum(:updated_at)&.to_i,
      Job.where(chat_goal_id: goal.id).maximum(:updated_at)&.to_i,
      Epic.where(chat_goal_id: goal.id).maximum(:updated_at)&.to_i
    ].compact.join(":").presence || "goal:#{goal.id}:empty"
  end
end
