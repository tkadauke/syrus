module Workflows
  # Operator- or chat-triggered on-demand visual QA pass over a Job's
  # already-implemented diff.
  #
  # Unlike the automatic visual_review loop (which pairs implement/respond
  # with visual_review inside Initial/PrFeedback/ChatFeedback/Retry so a
  # needs_work verdict can drive another implementation iteration), this
  # workflow runs the reviewer alone against whatever is already on the
  # branch — for a fresh look after the operator asks for one, or to cover
  # a visual pass that was skipped or never configured when the Job was
  # first implemented. It does not loop back into implement/respond; the
  # reviewer's verdict and critique are recorded on this workflow the same
  # way an automatic pass records them.
  class ManualVisualReview < Base
    def self.trigger_kind = "manual_visual_review"

    def self.steps_for(job)
      prepare_then(job, "visual_review")
    end
  end
end
