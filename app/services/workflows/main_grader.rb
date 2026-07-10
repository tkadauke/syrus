module Workflows
  # Runs .syrus.yml graders against the repository's default branch HEAD
  # to detect broken main before in-flight Jobs rebase onto it. Triggered
  # by MainGraderWorkflowJob when PollMainBranchHealthJob detects a new HEAD
  # SHA.
  #
  # Chain: grader_fanout → <per-grader steps> → grader_collect
  #
  # The chain has no retry loop: the result is binary — graders pass (healthy)
  # or fail (broken). after_success / after_fail update repository.grader_health
  # and call MainHealthChangedService when the health signal transitions.
  # The anchor Job is closed by the hook in both cases; it is excluded from
  # the operator UI (main_grader kind is filtered out of dashboard queries).
  class MainGrader < Base
    steps :grader_fanout, :grader_collect

    def self.trigger_kind = "main_grader"

    def self.queue_name = :default

    def self.after_success(workflow)
      update_grader_health!(workflow, "healthy")
    end

    def self.after_fail(workflow)
      update_grader_health!(workflow, "broken")
    end

    private_class_method def self.update_grader_health!(workflow, health)
      repository = workflow.job.repository
      previous_health = repository.main_health
      repository.update!(grader_health: health)
      repository.reload

      if repository.main_health != previous_health
        MainHealthChangedService.on_health_change!(repository)
      end

      StateTransition.with_source("system") do
        job = workflow.job
        job.close! if job.may_close?
        job.save!
      end
    end
  end
end
