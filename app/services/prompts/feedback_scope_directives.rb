module Prompts
  # What a feedback (respond) agent does not have to do itself. Without this
  # an agent asked to retitle the PR or file follow-up work looked for a way
  # to edit GitHub, found none, and blocked -- which cancelled the very
  # refresh_job_metadata step that would have done it. One sentence per line
  # so prompt specs can match each directive whole.
  module FeedbackScopeDirectives
    LINES = [
      "You do not edit the PR title, PR description or Job summary: a later refresh_job_metadata step in this workflow rewrites them from the Job and this feedback, so a request to change them is never a reason to block.",
      "When the feedback asks for separate follow-up work, file it with propose_job; it creates a Job that waits for the operator to accept it.",
      "If the feedback needs no code change, make no commit and say so in submit_summary."
    ].freeze
  end
end
