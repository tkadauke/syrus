require "delegate"

module AttentionItems
  # Most `PendingActions::*#execute` implementations resolve their target Job
  # via `user.jobs.find(...)` (`PendingActions::Base#action_job`) -- scoped to
  # Jobs the acting user created. That is right for chat, where the acting
  # user is a Job's own owner. An operator acting from the attention queue is
  # very often *not* that Job's creator -- escalations exist precisely because
  # a person other than the requester has to look at it.
  #
  # `PendingActions::Base#repair_action_job` already resolves this the way we
  # want -- `user.admin? ? Job.all : user.jobs` -- for actions flagged
  # `repairs_job!`. This wraps an admin `User` so every action, repair-flagged
  # or not, sees the same "admin can act on any Job" scope, without touching
  # `PendingActions::Base` or any of its ~20 subclasses.
  class AdminActingUser < SimpleDelegator
    def jobs
      admin? ? Job.all : __getobj__.jobs
    end
  end
end
