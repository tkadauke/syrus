module Syrus
  module Host
    # Relations over the activity records plugin reports read: approvals,
    # transitions, review comments, proposals, engagement samples, job logs,
    # spend entries, steps, and agent processes. Each returns a relation;
    # schema and persistence are not promised.
    module ActivityRecords
      RECORDS = {
        job_approvals: "JobApproval", state_transitions: "StateTransition", pr_review_comments: "PrReviewComment",
        chat_proposals: "ChatProposal", ui_engagement_samples: "UiEngagementSample", job_logs: "JobLog",
        chat_spend_entries: "ChatSpendEntry", steps: "Step", spawned_processes: "SpawnedProcess"
      }.freeze

      RECORDS.each do |name, model|
        define_singleton_method(name) { model.constantize.all }
      end
    end
  end
end
