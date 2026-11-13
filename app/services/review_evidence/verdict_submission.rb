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
      existing = recover_missing_receipt!(run:, evidence:, artifact_key:, existing:)
      evidence&.mark_submitted! unless evidence&.state == "submitted"
      return existing
    end

    target = evidence&.review_target || run.step.details.to_h["reviewer_target"]
    receipt = evidence&.persistence_receipt.presence ||
      persist_review_update(target:, run:, verdict:, key_learning: key_learning.presence || critique)
    evidence&.record_persistence_receipt!(receipt) if receipt

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
          "verdict" => verdict,
          "key_learning" => (key_learning.presence if target.present?)
        }
        if target.present?
          entry["review_context_manifest"] = evidence&.context_manifest.presence || run.step.details.to_h["review_context_manifest"]
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
        end
        if run.step.details.to_h["panel_id"].present?
          entry.merge!("provider" => run.agent_provider, "model" => run.model,
                       "panel_id" => run.step.details["panel_id"])
        end
        iterations << entry.compact
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

  # A verdict recorded while the owning plugin was unavailable has no receipt.
  # Resubmitting retries only the post-verdict update and patches the existing
  # artifact entry, so the retry recovers without duplicating the verdict.
  # Recovery uses only the values stored with the original submission, never the
  # resubmitted ones, so the plugin journal cannot diverge from recorded evidence.
  def recover_missing_receipt!(run:, evidence:, artifact_key:, existing:)
    return existing unless evidence
    return existing if evidence.persistence_receipt.present?

    target = evidence.review_target
    return existing if target.blank?

    receipt = persist_review_update(target:, run:, verdict: existing["verdict"],
                                    key_learning: existing["key_learning"].presence || existing["critique"])
    return existing unless receipt

    evidence.record_persistence_receipt!(receipt)
    run.workflow.with_lock do
      iterations = Array(run.workflow.artifact(artifact_key)).map do |entry|
        next entry unless entry["run_id"] == run.id

        existing = entry.merge(
          "persistence_receipt" => receipt,
          "memory_persistence" => { "state" => "persisted",
                                    "persisted_commit_sha" => receipt.dig("details", "persisted_commit_sha") }.compact
        )
      end
      run.workflow.set_artifact!(artifact_key, iterations)
      run.step.update!(details: run.step.details.to_h.merge("review_persistence_receipt" => receipt))
    end
    existing
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
