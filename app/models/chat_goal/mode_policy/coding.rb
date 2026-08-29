class ChatGoal::ModePolicy::Coding < ChatGoal::ModePolicy
  def validate(goal)
    goal.errors.add(:auto_file_proposals, "is only available in planning mode") if goal.auto_file_proposals?
  end
end
