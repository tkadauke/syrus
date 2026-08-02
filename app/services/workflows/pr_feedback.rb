module Workflows
  # Reviewer left a comment on the PR. Address it on the existing
  # branch, push.
  #
  #   prepare → retry_until(respond, grade) → summarize_amend → try(push)
  #     on remote-branch rebase conflict:
  #       push_agent_rebase → retry_until(grade, repair: landing_fix) → push_after_rebase
  #
  # respond runs the agent with the comment text + diff context —
  # *fresh* agent session (no --resume from the prior workflow's
  # implement; cross-workflow resume gets unwieldy and the prompt
  # already carries the context the agent needs). summarize_amend
  # --resumes respond and produces the *commit message for the
  # amendment* (not a fresh PR title). push is non-agentic.
  class PrFeedback < Base
    extend Workflows::FeedbackHandling

    steps :prepare,
          Workflows::RetryUntil.new(repair: [ :respond ], check: [ :grader_fanout, :grader_collect ]),
          :coverage_analyze,
          :coverage_pr_comment,
          :summarize_amend,
          :refresh_job_metadata,
          follow_up_push

    def self.trigger_kind = "pr_comment"

    def self.steps_for(job)
      [
        "prepare",
        adversarial_review_loop(job),
        Workflows::RetryUntil.new(
          max_iterations: AppSetting.grade_max_iterations,
          repair: [ :respond ],
          check: [ :grader_fanout, :grader_collect ]
        ),
        "coverage_analyze",
        "coverage_pr_comment",
        "summarize_amend",
        "refresh_job_metadata",
        follow_up_push(max_iterations: AppSetting.grade_max_iterations)
      ].compact
    end

    def self.adversarial_review_loop(job)
      rounds = adversarial_review_rounds(job)
      return nil unless rounds.positive?

      Workflows::Loop.new(max_iterations: rounds, steps: [ :respond, :adversarial_review ])
    end

    # Mark the most recently-addressed PR comment so the feedback
    # poller doesn't re-enqueue the same comment as fresh work on
    # the next tick. The comments + timestamps came in via the
    # workflow's artifacts when PollPullRequestJob enqueued this.
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
