module Workflows
  # Runs .syrus.yml graders against the repository's default branch HEAD
  # to detect broken main before in-flight Jobs rebase onto it. Triggered
  # by MainGraderWorkflowJob when PollMainBranchHealthJob detects a new HEAD
  # SHA.
  #
  # Chain: prepare → grader_fanout → <per-grader steps> → grader_collect
  #
  # The chain has no repair loop: actual grader failures mark main as broken.
  # Timeouts mark the grader signal inconclusive so operators can inspect or
  # tune the timeout without spawning a speculative repair job. Infrastructure
  # interruptions (for example a worker killed during deploy) leave health
  # unknown and enqueue a replacement check for the same SHA.
  # after_success / after_fail update repository.grader_health and call
  # MainHealthChangedService when the health signal transitions.
  # The anchor Job is closed by the hook in both cases; it is excluded from
  # the operator UI (main_grader kind is filtered out of dashboard queries).
  class MainGrader < Base
    SOLID_QUEUE_PRIORITY = Job::PRIORITY_TO_SQ.fetch("urgent") - 10

    steps :prepare, :grader_fanout, :grader_collect

    def self.trigger_kind = "main_grader"

    def self.queue_name = :runs

    def self.solid_queue_priority(_job) = SOLID_QUEUE_PRIORITY

    def self.after_success(workflow)
      update_grader_health!(workflow, "healthy")
    end

    def self.after_fail(workflow)
      failed_steps = failed_required_grader_steps(workflow)
      interrupted_steps, remaining_failures = failed_steps.partition { |step| infrastructure_interrupted_grader?(step) }
      inconclusive_steps, actual_failures = remaining_failures.partition { |step| inconclusive_grader?(workflow, step) }
      failed_names = failed_required_grader_names(actual_failures)

      if failed_names.any?
        update_grader_health!(workflow, "broken", failed_names)
      elsif inconclusive_steps.any?
        update_grader_health!(workflow, "inconclusive", failed_required_grader_names(inconclusive_steps))
      elsif interrupted_steps.any?
        if conclusive_grader_result_exists?(workflow)
          Rails.logger.info(
            "[Workflows::MainGrader] Workflow ##{workflow.id} interrupted after a conclusive " \
            "grader result already existed for #{workflow.job.repository.slug}@#{workflow.artifact("main_sha")}; " \
            "skipping duplicate replacement"
          )
          close_anchor_job!(workflow)
          return
        end

        record_interrupted_grader_check!(workflow, interrupted_steps)
        enqueue_replacement_check!(workflow)
        close_anchor_job!(workflow)
      else
        Rails.logger.warn(
          "[Workflows::MainGrader] Workflow ##{workflow.id} failed before required graders reported failures; " \
          "leaving #{workflow.job.repository.slug} grader_health=#{workflow.job.repository.grader_health}"
        )
        close_anchor_job!(workflow)
      end
    end

    private_class_method def self.update_grader_health!(workflow, health, failed_names = nil)
      repository = workflow.job.repository
      previous_health = repository.main_health
      was_landing_paused = repository.landing_paused?
      repository.update!(grader_health: health)
      MainBranchHealthCheck.record_grader_workflow(
        repository: repository,
        workflow: workflow,
        sha: workflow.artifact("main_sha").to_s.presence || "unknown",
        grader_health: health,
        grader_failed_names: failed_names
      )
      repository.reload

      if repository.main_health != previous_health || (was_landing_paused && repository.main_health == "healthy")
        MainHealthChangedService.on_health_change!(repository)
      elsif repository.main_health_broken?
        MainHealthChangedService.ensure_repair_job!(repository)
      end

      close_anchor_job!(workflow)
    end

    private_class_method def self.failed_required_grader_steps(workflow)
      workflow.steps
              .where(kind: "grader", state: "failed")
              .select do |step|
                details = step.details || {}
                details["required"]
              end
    end

    private_class_method def self.failed_required_grader_names(steps)
      steps.map do |step|
        details = step.details || {}
        details["name"].presence || "unnamed"
      end
    end

    private_class_method def self.infrastructure_interrupted_grader?(step)
      latest_failed_run = step.runs.where(state: "failed").order(created_at: :desc).first
      return false unless latest_failed_run

      latest_failed_run.agent_outcome == "worker_died" ||
        latest_failed_run.run_failure_classification&.classification == "worker_died"
    end

    private_class_method def self.inconclusive_grader?(workflow, step)
      return false if workflow.job.repository.treat_grader_timeouts_as_failures?

      GraderFailureSignal.timeout_like_step?(step)
    end

    private_class_method def self.record_interrupted_grader_check!(workflow, interrupted_steps)
      repository = workflow.job.repository
      interrupted_names = failed_required_grader_names(interrupted_steps)
      MainBranchHealthCheck.record_grader_workflow(
        repository: repository,
        workflow: workflow,
        sha: workflow.artifact("main_sha").to_s.presence || "unknown",
        grader_health: "unknown",
        grader_failed_names: interrupted_names
      )
      Rails.logger.warn(
        "[Workflows::MainGrader] Workflow ##{workflow.id} interrupted while running required graders " \
        "#{interrupted_names.join(", ")}; leaving #{repository.slug} grader_health=#{repository.grader_health}"
      )
    end

    private_class_method def self.conclusive_grader_result_exists?(workflow)
      sha = workflow.artifact("main_sha").to_s.presence
      return false unless sha

      MainBranchHealthCheck.conclusive_grader_result_exists?(
        repository: workflow.job.repository,
        sha: sha
      )
    end

    private_class_method def self.enqueue_replacement_check!(workflow)
      sha = workflow.artifact("main_sha").to_s.presence
      return unless sha
      return if conclusive_grader_result_exists?(workflow)

      MainGraderWorkflowJob.perform_later(workflow.job.repository_id, sha)
    end

    private_class_method def self.close_anchor_job!(workflow)
      StateTransition.with_source("system") do
        job = workflow.job
        job.close_with_reason!(Job::MAIN_GRADER_CLOSURE_REASON) if job.may_close?
      end
    end
  end
end
