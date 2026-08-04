module SyrusChatMcp
  module BranchDivergenceToolSupport
    include AdminPendingActionToolSupport

    private

    def divergence_records(job_id, workflow_id)
      normalized_job_id = integer_param(job_id, "job_id")
      return [ nil, nil, nil, normalized_job_id ] if normalized_job_id.is_a?(MCP::Tool::Response)

      normalized_workflow_id = integer_param(workflow_id, "workflow_id")
      return [ nil, nil, nil, normalized_workflow_id ] if normalized_workflow_id.is_a?(MCP::Tool::Response)

      job = Job.find_by(id: normalized_job_id)
      return [ nil, nil, nil, structured_error("job_not_found", "job not found: #{normalized_job_id}") ] unless job

      workflow = job.workflows.find_by(id: normalized_workflow_id)
      return [ nil, nil, nil, structured_error("workflow_not_found", "workflow not found for #{job.slug}: #{normalized_workflow_id}") ] unless workflow
      return [ nil, nil, nil, structured_error("missing_branch_divergence", "workflow has no recorded branch divergence") ] unless workflow.artifact("branch_divergence").present?

      evidence = BranchDivergenceResolutionEvidence.for(job: job, workflow: workflow)
      [ job, workflow, evidence, nil ]
    end

    def structured_error(code, message, extra = {})
      MCP::Tool::Response.new(
        [ { type: "text", text: JSON.generate({ error: code, message: message }.merge(extra)) } ],
        error: true
      )
    end

    def evidence_message(prefix, evidence)
      "#{prefix} Evidence: remote=#{short(evidence['remote_sha']) || 'unknown'}, workflow_local=#{short(evidence['workflow_local_sha']) || 'unknown'}, base=#{short(evidence['base_sha']) || 'unknown'}, files=#{Array(evidence.dig('diff_summary', 'files')).size}."
    end

    def short(sha)
      sha.to_s.presence&.first(12)
    end
  end
end
