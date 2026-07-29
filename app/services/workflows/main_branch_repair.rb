module Workflows
  # Repair workflow for a broken main branch. Spawned by
  # MainHealthChangedService when main_health transitions to broken.
  #
  # Chain:
  #   prepare → preflight_grader_fanout → <preflight_grader steps> → preflight_grader_collect
  #     → retry_until(implement, grader_fanout, grader_collect)
  #     → summarize → test_plan → pr_open
  #
  # Prepare runs first so that graders have installed dependencies available
  # (bundle install, npm ci, etc.) — many graders require them.
  #
  # The preflight phase runs graders against the current workspace before
  # the agent is invoked. If all required graders pass, the broken signal was
  # a false positive. PreflightGraderCollect cancels the downstream implement
  # chain and after_success marks the repository healthy without the agent running.
  #
  # If graders fail in the preflight phase, the chain continues normally:
  # implement → grade loop → summarize → test_plan → pr_open. The agent
  # implements a fix, opens a PR, and PollPullRequestJob calls
  # MainHealthChangedService.repair_landed! when the PR merges.
  class MainBranchRepair < Base
    steps :prepare,
          :preflight_grader_fanout, :preflight_grader_collect,
          Workflows::RetryUntil.new(repair: [ :implement ], check: [ :grader_fanout, :grader_collect ]),
          :summarize, :test_plan, :pr_open

    def self.trigger_kind = "main_branch_repair"

    def self.steps_for(job)
      chain = [
        "prepare",
        "preflight_grader_fanout",
        "preflight_grader_collect",
        Workflows::RetryUntil.new(
          max_iterations: AppSetting.grade_max_iterations,
          repair: [ :implement ],
          check: [ :grader_fanout, :grader_collect ]
        ),
        "summarize",
        "test_plan",
        "pr_open"
      ]
      prepare_skipped_for?(job) ? chain.reject { |node| node == "prepare" } : chain
    end

    # Called when the workflow finishes successfully.
    #
    # Full-repair path (preflight graders failed → agent fixed the code →
    # PR opened): no action here. The normal job lifecycle handles approval
    # and landing; PollPullRequestJob calls MainHealthChangedService.repair_landed!
    # when the PR merges.
    #
    # Preflight path (graders passed → no fix needed): update grader_health
    # to healthy, notify MainHealthChangedService of the transition so landing
    # can resume, and close the anchor job.
    def self.after_success(workflow)
      return unless workflow.artifact("preflight_passed")

      repository = workflow.job.repository
      previous_health = repository.main_health
      was_landing_paused = repository.landing_paused?

      repository.update!(grader_health: "healthy")
      MainBranchHealthCheck.record_grader_workflow(
        repository: repository,
        workflow: workflow,
        sha: repository.last_health_checked_sha.to_s.presence || "unknown",
        grader_health: "healthy",
        grader_failed_names: []
      )
      repository.reload

      if repository.main_health != previous_health || (was_landing_paused && repository.main_health == "healthy")
        MainHealthChangedService.on_health_change!(repository)
      end

      close_anchor_job!(workflow)
    end

    private_class_method def self.close_anchor_job!(workflow)
      StateTransition.with_source("system") do
        job = workflow.job
        job.close_with_reason!("preflight_passed") if job.may_close?
      end
    end
  end
end
