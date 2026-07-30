module Workflows
  # Approved external PR ready to land.
  #
  #   mergeability_preflight → grader_fanout → grader_collect → external_pr_merge
  #
  # Graders run on the external PR's HEAD to validate before merging.
  # No prepare or push steps — Syrus does not own this branch.
  # On grader failure Syrus posts a REQUEST_CHANGES review on the PR
  # (fork-aware: message differs for forks vs same-repo contributors)
  # then calls fail_landing! to revert the job to :implemented so the
  # operator can address the issues before re-approving.
  class ExternalPrMerge < Base
    steps :mergeability_preflight,
          :grader_fanout,
          :grader_collect,
          :external_pr_merge

    def self.trigger_kind = "external_pr_merge"

    def self.queue_name = :merges

    def self.after_success(_workflow)
      LandingQueueProcessor.try_land!
    end

    def self.after_fail(workflow)
      job = workflow.job
      return unless job&.landing?

      post_grader_failure_review!(workflow) if grader_failure?(workflow)

      LandingFailureHandler.call(job: job, reason: failure_reason_for(workflow), run: latest_failed_run(workflow))
    end

    def self.failure_reason_for(workflow)
      explicit_reason = workflow.failure_reason.presence || workflow.artifact("failure_reason").presence
      return explicit_reason if explicit_reason

      run = latest_failed_run(workflow)
      diagnostic = run&.run_diagnostic
      return "#{diagnostic.error_class}: #{diagnostic.error_message}" if diagnostic

      "external_pr_merge workflow failed"
    end

    def self.latest_failed_run(workflow)
      workflow.runs.where(state: "failed").includes(:run_diagnostic).order(created_at: :desc).first
    end

    def self.grader_failure?(workflow)
      workflow.steps.where(kind: "grader_collect", state: "failed").exists?
    end

    # Posts a REQUEST_CHANGES review on the external PR when required graders
    # fail at landing. Fork PRs can't be auto-fixed by Syrus, so the message
    # asks the contributor to push a fix to their branch. Same-repo PRs get
    # the same notification since the ExternalPrMerge workflow has no repair
    # step; the operator re-approves after the contributor pushes a fix.
    def self.post_grader_failure_review!(workflow)
      job = workflow.job
      client = GithubClient.for(repository: job.repository, user: job.user)
      pr = client.pull_request(job.repository.slug, job.external_pr_number)

      is_fork = pr.head&.repo&.full_name != job.repository.slug

      failed_names = workflow.steps
                             .where(kind: "grader", state: "failed")
                             .filter_map { |s| s.details&.fetch("name", nil) }

      body = build_grader_failure_body(failed_names, is_fork)
      client.create_pr_review(job.repository.slug, job.external_pr_number,
                              event: "REQUEST_CHANGES", body: body)
    rescue StandardError => e
      Rails.logger.warn("[ExternalPrMerge] grader failure review failed for Job ##{job.id}: #{e.class}: #{e.message}")
    end

    def self.build_grader_failure_body(failed_names, is_fork)
      lines = [ "Syrus ran required checks on this pull request before landing and the following failed:" ]
      lines << ""
      failed_names.each { |name| lines << "- **#{name}**" }
      lines << ""
      lines << if is_fork
        "Please fix the failing checks and push a new commit to your branch."
      else
        "Please fix the failing checks and push a new commit to this branch."
      end
      lines.join("\n")
    end
  end
end
