module Workflows
  class CheckpointResume < Base
    def self.trigger_kind = "retry"

    def self.instantiate(job:, artifacts:, agent_provider: nil)
      chain_template = Array(artifacts.fetch("checkpoint_resume_steps")).map(&:to_s)
      raise "no checkpoint resume steps declared" if chain_template.empty?

      effective_chain_template = without_skipped_prepare(job, chain_template)
      effective_artifacts = artifacts
      if effective_chain_template != chain_template
        effective_artifacts = effective_artifacts.merge(
          "prepare_skipped" => true,
          "prepare_skipped_reason" => job.prepare_skip_reason
        )
      end

      Workflow.transaction do
        wf = Workflow.create!(
          job: job,
          trigger_kind: trigger_kind,
          agent_provider: agent_provider.presence || job.workflow_agent_provider || job.agent_provider || job.user.agent_provider,
          chain_template: serialize_chain_template(effective_chain_template),
          artifacts: effective_artifacts
        )
        steps = materialize_steps!(wf, effective_chain_template)
        steps.each_cons(2) { |step, next_step| step.update!(next_step_id: next_step.id) }
        wf
      end
    end
  end
end
