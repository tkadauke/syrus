module ReviewEvidence::VerdictSubmission
  module_function

  def call!(run:, artifact_key:, review_kind:, critique:, verdict:, key_learning: nil)
    evidence = ReviewEvidence.find_by(run_id: run.id)
    if evidence
      ReviewEvidence::VerifySubmission.call!(
        evidence: evidence,
        workspace_path: WorkflowWorkspace.new(run.workflow).path
      )
    end

    existing = existing_submission(run.workflow, artifact_key, run.id)
    if existing
      evidence&.mark_submitted! unless evidence&.state == "submitted"
      return existing
    end

    target = run.step.details.to_h["reviewer_target"]
    receipt = persist_review_update(target:, run:, verdict:, key_learning: key_learning.presence || critique)
    reviewer = evidence&.reviewer
    if target.blank? && reviewer&.respond_to?(:finalize_review_memory!)
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
        if target.present?
          entry["review_context_manifest"] = run.step.details.to_h["review_context_manifest"]
          entry["reviewer"] = {
            "label" => [ target.dig("display", "name"), App::Presentation.agent_provider_label(run.agent_provider) ].compact.join(" · "),
            "type" => target["type"],
            "reference" => target["reference"],
            "provider" => run.agent_provider,
            "model" => run.model
          }.compact
          entry["persistence_receipt"] = receipt
          entry["memory_persistence"] = {
            "state" => receipt.present? ? "persisted" : "missing",
            "persisted_commit_sha" => receipt&.dig("details", "persisted_commit_sha")
          }.compact
        elsif reviewer&.respond_to?(:review_context_manifest)
          entry["review_context_manifest"] = reviewer.review_context_manifest(run)
          context = reviewer.review_context_for(run)
          entry["reviewer"] = {
            "label" => "#{reviewer.display_name} · #{App::Presentation.agent_provider_label(run.agent_provider)}",
            "provider" => run.agent_provider, "model" => run.model
          }
          entry["memory_persistence"] = {
            "state" => context&.persistence_state || "missing", "persisted_commit_sha" => context&.persisted_commit_sha,
            "error_code" => context&.persistence_error_code
          }.compact
        end
        if run.step.details.to_h["panel_id"].present?
          entry.merge!("provider" => run.agent_provider, "model" => run.model,
                       "panel_id" => run.step.details["panel_id"])
        end
        iterations << entry.compact
        evidence&.record_persistence!(receipt) if receipt
        run.step.update!(details: run.step.details.to_h.merge("review_persistence_receipt" => receipt)) if receipt
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

  def existing_submission(workflow, artifact_key, run_id)
    Array(workflow.reload.artifact(artifact_key)).find { |candidate| candidate["run_id"] == run_id }
  end

  def persist_review_update(target:, run:, verdict:, key_learning:)
    return if target.blank?

    ReviewContextContributions.persist(
      target:, run:, context: run.step.details.to_h.slice("review_context_manifest"),
      verdict:, update: { "key_learning" => key_learning }
    )
  rescue ReviewContextContributions::Unavailable
    nil
  end
end
