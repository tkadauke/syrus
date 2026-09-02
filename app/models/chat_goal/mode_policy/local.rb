class ChatGoal::ModePolicy::Local < ChatGoal::ModePolicy::Coding
  def requires_ready_coding_checkout_for_continuation?(_goal)
    false
  end
end
