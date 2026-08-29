class ChatGoalProvenance
  def self.attributes_for(chat_session)
    goal = chat_session&.active_goal
    return {} unless goal&.active?

    {
      chat_goal: goal,
      goal_prompt_snapshot: snapshot(goal)
    }
  end

  def self.payload_for(record)
    goal_id = record&.chat_goal_id
    snapshot = record&.goal_prompt_snapshot
    return nil if goal_id.blank? && snapshot.blank?

    {
      chat_goal_id: goal_id,
      prompt_snapshot: snapshot || {}
    }
  end

  def self.snapshot(goal)
    {
      "id" => goal.id,
      "chat_session_id" => goal.chat_session_id,
      "user_id" => goal.user_id,
      "repository_id" => goal.repository_id,
      "prompt" => goal.prompt,
      "completion_condition" => goal.completion_condition,
      "mode_snapshot" => goal.mode_snapshot || {},
      "status" => goal.status,
      "approval_policy" => goal.approval_policy,
      "auto_file_proposals" => goal.auto_file_proposals?,
      "auto_submit_jobs" => goal.auto_submit_jobs?,
      "iteration_count" => goal.iteration_count.to_i,
      "created_at" => goal.created_at&.iso8601,
      "updated_at" => goal.updated_at&.iso8601
    }
  end
end
