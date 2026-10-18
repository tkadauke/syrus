class RepositoryExecutionProbeGate
  def self.blocking_probe_for(workflow)
    return unless workflow.trigger_kind == "initial"
    return if workflow.job.repository.jobs.joins(workflows: { steps: :runs }).where(steps: { kind: "implement" }).where.not(runs: { id: nil }).where.not(jobs: { id: workflow.job_id }).exists?

    probe = workflow.job.repository.repository_execution_probes.recent_first.first
    probe if probe&.implementation_blocking?
  end
end
