module Coworkers
  class Workflow < ::Workflows::Base
    steps :prepare, :coworker_run, :post_to_chat, :auto_close

    def self.trigger_kind = "coworker_run"
    def self.queue_name = :runs

    def self.instantiate(job:, artifacts: nil, **options)
      coworker = Coworkers::Coworker.find(job.origin_id)
      branch_artifact = { WorkflowWorkspace::REQUIRED_BRANCH_ARTIFACT => "coworkers/#{coworker.handle}" }
      super(job:, artifacts: branch_artifact.merge(artifacts.to_h), **options)
    end

    def self.after_fail(workflow)
      Coworkers::PostToChat.post_failure!(workflow) if workflow.steps.where(kind: "coworker_run", state: "failed").exists?
      scheduled_task_for(workflow)&.record_failure!
    ensure
      close_anchor_job!(workflow)
    end

    def self.after_success(workflow)
      scheduled_task_for(workflow)&.record_success!
    end

    private_class_method def self.close_anchor_job!(workflow)
      StateTransition.with_source("system") do
        workflow.job.close_with_reason!(workflow.job.kind) if workflow.job.may_close?
      end
    end

    private_class_method def self.scheduled_task_for(workflow)
      return if workflow.job.scheduled_task_id.blank?

      ScheduledTasks::Task.find_by(id: workflow.job.scheduled_task_id)
    end
  end
end
