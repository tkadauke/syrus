module SyrusMcp
  # Shared best-effort provenance derivation for Workflow#set_typed_artifact!
  # callers (SubmitArtifactTool, SubmitVisualArtifactTool). Centralizes the
  # "derive from the current run/workflow and the matching DiffReviewVersion"
  # lookup described in the version-aware review artifacts design so both
  # tools tag entries the same way.
  module TypedArtifactProvenance
    module_function

    def for_run(run)
      return {} unless run

      version = DiffReviewVersion.best_match_for(job_id: run.job_id, run_id: run.id, workflow_id: run.workflow_id)
      {
        run_id: run.id,
        step_id: run.step_id,
        base_sha: version&.base_sha.presence || run.base_sha.presence,
        head_sha: version&.head_sha.presence || run.head_sha.presence,
        diff_review_version_id: version&.id
      }.compact
    end
  end
end
