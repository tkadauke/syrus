class ChatGoal::ModePolicy::Coding < ChatGoal::ModePolicy
  def validate(goal)
    goal.errors.add(:auto_file_proposals, "is only available in planning mode") if goal.auto_file_proposals?
  end

  def auto_submit_coding_handoff?(goal)
    goal.auto_submit_jobs?
  end

  def requires_ready_coding_checkout_for_continuation?(_goal)
    true
  end
end
