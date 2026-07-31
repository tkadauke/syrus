module Workflows
  module FeedbackHandling
    def mark_source_comments_handled(workflow)
      source_comments(workflow).find_each do |comment|
        comment.mark_handled!
      end
    end

    def mark_source_comments_failed(workflow)
      reason = feedback_failure_reason(workflow)
      source_comments(workflow).find_each do |comment|
        comment.mark_handling_failed!(reason: reason)
      end
    end

    private

    def source_comments(workflow)
      ids = source_comment_ids(workflow)
      return workflow.job.pr_review_comments.none if ids.empty?

      workflow.job.pr_review_comments.where(id: ids)
    end

    def source_comment_ids(workflow)
      ids = Array(workflow.artifact("pr_review_comment_ids")).map(&:to_i).select(&:positive?)
      source_id = workflow.artifact("feedback_source").to_h["pr_review_comment_id"].to_i
      ids << source_id if source_id.positive?
      ids.presence || source_comment_ids_from_github_artifacts(workflow)
    end

    def source_comment_ids_from_github_artifacts(workflow)
      github_ids = Array(workflow.artifact("pr_comments")).filter_map { |comment| comment["id"] || comment[:id] }
      return [] if github_ids.empty?

      workflow.job.pr_review_comments.where(github_comment_id: github_ids).pluck(:id)
    end

    def feedback_failure_reason(workflow)
      run = workflow.runs.where(state: "failed").includes(:run_failure_classification).order(created_at: :desc).first
      classification = run&.run_failure_classification
      classification&.reason.presence ||
        classification&.classification.presence ||
        run&.agent_outcome.presence ||
        "workflow_failed"
    end
  end
end
