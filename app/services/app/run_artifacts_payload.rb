module App
  # Shared JSON shape for a single Run's transcript log + diff artifacts.
  # Used by the operator-scoped Api::V1::App::JobsController#run_artifacts
  # (ownership-scoped via find_job_by_param) and by any admin-gated
  # counterpart (e.g. the agent_activity plugin's admin controller) that
  # needs the same payload for a Run the caller reached through a different
  # authorization path -- keeping one source of truth for the field list so
  # the two callers' payloads can't silently drift apart.
  class RunArtifactsPayload
    def self.build(run:)
      logs = serialize_logs(run)

      {
        job_id: run.job_id,
        workflow_id: run.step&.workflow_id,
        run_id: run.id,
        base_ref: run.base_sha,
        head_ref: run.head_sha,
        agent_diff: run.agent_diff,
        agent_diff_bytes: run.agent_diff&.bytesize || 0,
        step_agent_diff: run.step_agent_diff,
        logs_count: logs.size,
        logs: logs
      }
    end

    def self.serialize_logs(run)
      run.job_logs
        .order(:sequence)
        .pluck(:id, :sequence, :kind, :chunk, :created_at)
        .map do |id, sequence, kind, chunk, created_at|
          {
            id: id,
            sequence: sequence,
            kind: kind,
            chunk: chunk,
            created_at: created_at&.iso8601
          }
        end
    end
  end
end
