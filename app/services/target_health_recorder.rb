class TargetHealthRecorder
  WORKFLOW_ARTIFACT_KEY = "target_health_record_refs".freeze

  def self.record!(...) = new.record!(...)

  def record!(repository:, target_label:, project_id:, commit_sha:, input_fingerprint:,
              command_fingerprint:, environment_fingerprint:, status:, workflow: nil,
              step: nil, run: nil, checked_at: Time.current, started_at: nil,
              finished_at: nil, duration_s: nil, exit_code: nil, log_path: nil,
              log_bytes: nil, artifacts: {}, metadata: {})
    record = TargetHealthRecord.find_or_initialize_by(
      repository: repository,
      target_label: target_label,
      commit_sha: commit_sha,
      input_fingerprint: input_fingerprint,
      command_fingerprint: command_fingerprint,
      environment_fingerprint: environment_fingerprint
    )

    record.assign_attributes(
      workflow: workflow,
      step: step,
      run: run,
      project_id: project_id,
      status: status,
      checked_at: checked_at,
      started_at: started_at,
      finished_at: finished_at,
      duration_s: duration_s,
      exit_code: exit_code,
      log_path: log_path,
      log_bytes: log_bytes,
      artifacts: artifacts.presence || {},
      metadata: metadata.presence || {}
    )
    record.save!

    append_workflow_reference!(workflow, record) if workflow
    record
  end

  private

  def append_workflow_reference!(workflow, record)
    refs = Array(workflow.artifacts.to_h[WORKFLOW_ARTIFACT_KEY])
    ref = {
      "target_health_record_id" => record.id,
      "target_label" => record.target_label,
      "project_id" => record.project_id,
      "commit_sha" => record.commit_sha,
      "status" => record.status
    }

    refs.reject! { |entry| entry["target_health_record_id"].to_i == record.id }
    workflow.set_artifact!(WORKFLOW_ARTIFACT_KEY, refs.push(ref))
  end
end
