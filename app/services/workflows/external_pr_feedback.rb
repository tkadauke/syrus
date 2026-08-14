module Workflows
  # Reviewer feedback (issue/review comment) on a same-repo external_pr Job
  # (job.external_pr_fork? == false — e.g. a dependabot branch, or a
  # collaborator's branch on the tracked repo itself). Syrus already has
  # push access to the branch, so this behaves exactly like PrFeedback for
  # a Syrus-authored PR: address the feedback on the existing branch, push.
  #
  #   prepare → [loop(respond → adversarial_review)] → retry_until(respond → graders)
  #     → summarize_amend → try(push)
  #
  # No coverage_analyze/coverage_pr_comment/refresh_job_metadata — those
  # steps key off job.pr_number, which external_pr Jobs never set (they use
  # external_pr_number instead).
  #
  # Sourced from job.external_pr_number/job.branch_name instead of
  # job.pr_number/the syrus/... branch convention. Steps::Push already
  # pushes to workspace.branch_name generically (job.branch_name, whatever
  # its naming convention), so no branch-naming changes were needed there.
  class ExternalPrFeedback < Base
    extend Workflows::FeedbackHandling

    def self.trigger_kind = "external_pr_feedback"

    def self.steps_for(job)
      prepare_then(
        job,
        adversarial_review_loop(job, agent_step: :respond),
        grader_retry_loop(:respond),
        "summarize_amend",
        follow_up_push(max_iterations: AppSetting.grade_max_iterations)
      )
    end

    # Mark the most recently-addressed comment so PollExternalPrJob doesn't
    # re-enqueue the same comment as fresh work on the next poll.
    def self.after_success(workflow)
      addressed_at = Array(workflow.artifact("pr_comments")).filter_map do |comment|
        parse_comment_time(comment["created_at"])
      end.max

      workflow.job.mark_feedback_addressed!(addressed_at)
      mark_source_comments_handled(workflow)
      job = workflow.job
      NotificationService.create_for(
        user: job.user,
        kind: "pr_comment_addressed",
        job: job,
        pr_url: App::Presentation.job_pr_url(job) || App::Presentation.external_pr_url(job),
        body: "Syrus addressed your PR comments on #{job.slug}: #{job.title.truncate(80)}"
      )
    end

    def self.parse_comment_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def self.after_fail(workflow)
      mark_source_comments_failed(workflow)
    end

    def self.after_cancel(workflow)
      mark_source_comments_failed(workflow)
    end
  end
end
