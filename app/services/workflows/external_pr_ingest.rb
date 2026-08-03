module Workflows
  # Runs .syrus.yml graders on an externally-filed pull request immediately
  # after ingestion. Triggered by PollExternalOpenPrsJob when a new external_pr
  # Job is created.
  #
  # Same-repo PRs (we_control_head? == true, external_pr_fork? == false):
  #   prepare → retry_until(repair: landing_fix, check: grader_fanout → grader_collect) → push
  #
  # Fork PRs (external_pr_fork? == true):
  #   prepare → grader_fanout → grader_collect
  #
  # On grader pass (either kind): Job returns to :implemented via
  # propagate_succeed_to_job!.
  #
  # On grader failure:
  #   - Same-repo: after repair iterations are exhausted, after_fail drives Job
  #     to :failed so the operator can retry.
  #   - Fork: after_fail posts a REQUEST_CHANGES review comment and returns Job
  #     to :implemented (operator/contributor addresses and re-pushes; next
  #     poll cycle re-evaluates by creating a fresh workflow).
  #
  # propagate_fail_to_job! is suppressed for this trigger kind (see
  # Workflow#external_pr_ingest_workflow?). after_fail drives Job state
  # explicitly to keep the two PR kinds on different outcomes.
  class ExternalPrIngest < Base
    steps :prepare, :grader_fanout, :grader_collect

    def self.trigger_kind = "external_pr_ingest"

    def self.queue_name = :runs

    def self.steps_for(job)
      if job.external_pr_fork?
        ["prepare", "grader_fanout", "grader_collect"]
      else
        [
          "prepare",
          Workflows::RetryUntil.new(
            max_iterations: AppSetting.grade_max_iterations,
            repair_first: false,
            repair: [ :landing_fix ],
            check: [ :grader_fanout, :grader_collect ]
          ),
          "push"
        ]
      end
    end

    def self.after_fail(workflow)
      job = workflow.job

      if job.external_pr_fork?
        post_fork_review_comment!(workflow)
        StateTransition.with_source("system") do
          if job.may_mark_implemented?
            job.mark_implemented!
            job.save!
          end
        end
      else
        StateTransition.with_source("system") do
          if job.may_mark_failed?
            job.mark_failed!
            job.save!
          end
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[Workflows::ExternalPrIngest] after_fail raised for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
    end

    private_class_method def self.post_fork_review_comment!(workflow)
      job = workflow.job
      failed_names = failed_required_grader_names(workflow)
      return if failed_names.empty?

      body = review_body(failed_names)
      client = GithubClient.for(repository: job.repository, user: job.user)
      client.create_pr_review(
        job.repository.slug,
        job.external_pr_number,
        event: "REQUEST_CHANGES",
        body: body
      )
      Rails.logger.info("[Workflows::ExternalPrIngest] posted REQUEST_CHANGES review on #{job.repository.slug}##{job.external_pr_number} (#{failed_names.size} failed graders)")
    rescue StandardError => e
      Rails.logger.warn("[Workflows::ExternalPrIngest] review comment failed for Job ##{workflow.job.id}: #{e.class}: #{e.message}")
    end

    private_class_method def self.failed_required_grader_names(workflow)
      workflow.steps
              .where(kind: "grader", state: "failed")
              .select { |step| step.details&.dig("required") }
              .map { |step| step.details["name"].presence || "unnamed" }
    end

    private_class_method def self.review_body(failed_names)
      list = failed_names.map { |name| "- #{name}" }.join("\n")
      <<~BODY.strip
        Syrus ran the repository graders against this pull request and found failures:

        #{list}

        Please fix the failing checks and push an update. Syrus will re-evaluate when new commits arrive.
      BODY
    end
  end
end
