module ReviewEvidence::VerdictSubmission
  module_function

  def call!(run:, artifact_key:, review_kind:, critique:, verdict:)
    evidence = run.review_evidence
    if evidence
      ReviewEvidence::VerifySubmission.call!(
        evidence: evidence,
        workspace_path: WorkflowWorkspace.new(run.workflow).path
      )
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
        reviewer = evidence&.reviewer
        if reviewer&.respond_to?(:review_context_manifest)
          entry["review_context_manifest"] = reviewer.review_context_manifest(run)
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
