class ChatGoal::ModePolicy::Planning < ChatGoal::ModePolicy
  def validate(goal)
    goal.errors.add(:auto_submit_jobs, "is only available in coding or local mode") if goal.auto_submit_jobs?
  end
end
