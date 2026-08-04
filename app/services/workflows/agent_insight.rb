module Workflows
  # Runs an agent analysis pass over recent workflow runs for a repository
  # and surfaces improvement suggestions via InsightSuggestion records.
  # Modeled after MainGrader: infrastructure-flavored, no commits, no PR,
  # auto-closes the anchor Job on completion (success or failure).
  #
  # Chain: agent_insight_run → auto_close
  # Optional `.syrus.yml` opt-in:
  #   agent_insight:
  #     prepare: true
  # inserts the normal prepare step before the read-only insight pass.
  #
  # The anchor Job is closed by after_success and after_fail regardless of
  # workflow outcome so insight Jobs do not accumulate in the operator dashboard.
  class AgentInsight < Base
    steps :agent_insight_run, :auto_close

    def self.trigger_kind = "agent_insight"

    def self.queue_name = :runs

    def self.steps_for(job)
      chain = [ "agent_insight_run", "auto_close" ]
      RepoAgentInsightPlan.for_job(job).prepare? ? [ "prepare", *chain ] : chain
    end

    def self.after_success(workflow)
      close_anchor_job!(workflow)
    end

    def self.after_fail(workflow)
      close_anchor_job!(workflow)
    end

    private_class_method def self.close_anchor_job!(workflow)
      StateTransition.with_source("system") do
        job = workflow.job
        job.close_with_reason!("agent_insight") if job.may_close?
      end
    end
  end
end
