module ReviewEvidence::VerdictSubmission
  module_function

  def call!(run:, artifact_key:, review_kind:, critique:, verdict:, key_learning: nil)
    evidence = run.review_evidence
    if evidence
      ReviewEvidence::VerifySubmission.call!(
        evidence: evidence,
        workspace_path: WorkflowWorkspace.new(run.workflow).path
      )
    end

    reviewer = evidence&.reviewer
    if reviewer&.respond_to?(:finalize_review_memory!)
      reviewer.finalize_review_memory!(run:, key_learning: key_learning.presence || critique, verdict:)
    end

    ApplicationRecord.transaction do
      run.workflow.with_lock do
        iterations = Array(run.workflow.artifact(artifact_key))
        existing = iterations.find { |candidate| candidate["run_id"] == run.id }
        if existing
          evidence&.mark_submitted! unless evidence&.state == "submitted"
          return existing
        end
        entry = {
          "iteration" => run.step.iteration,
          "step_id" => run.step_id,
          "run_id" => run.id,
          "review_evidence_id" => evidence&.id,
          "critique" => critique,
          "verdict" => verdict
        }
        if reviewer&.respond_to?(:review_context_manifest)
          entry["review_context_manifest"] = reviewer.review_context_manifest(run)
          context = reviewer.review_context_for(run)
          entry["reviewer"] = {
            "label" => "#{reviewer.display_name} · #{App::Presentation.agent_provider_label(run.agent_provider)}",
            "type" => run.step.details.dig("reviewer_target", "type"),
            "reference" => run.step.details.dig("reviewer_target", "reference"),
            "provider" => run.agent_provider,
            "model" => run.model
          }.compact
          entry["memory_persistence"] = {
            "state" => context&.persistence_state || "missing",
            "persisted_commit_sha" => context&.persisted_commit_sha,
            "error_code" => context&.persistence_error_code
          }.compact
        end
        if run.step.details.to_h["panel_id"].present?
          entry.merge!("provider" => run.agent_provider, "model" => run.model,
                       "panel_id" => run.step.details["panel_id"])
        end
        iterations << entry.compact
        run.workflow.set_artifact!(artifact_key, iterations)
        ReviewFindingEvents.record(
          workflow: run.workflow, step: run.step, run: run,
          review_kind: review_kind, iteration: run.step.iteration,
          verdict: verdict, critique: critique
        )
        evidence&.mark_submitted!
      end
    end
  end
end
