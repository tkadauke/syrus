module ReviewEvidence::ArtifactPresentation
  module_function

  def call(entries, evidence_by_id: nil)
    entries = Array(entries)
    evidence_by_id ||= ReviewEvidence.where(id: evidence_ids(entries)).index_by(&:id)
    entries.map { |entry| present(entry, evidence_by_id) }
  end

  def present(entry, evidence_by_id)
    return entry unless entry.is_a?(Hash)

    evidence_id = entry["review_evidence_id"] || entry[:review_evidence_id]
    return entry.merge("review_evidence" => { "state" => "legacy" }) if evidence_id.blank?

    evidence = evidence_by_id[evidence_id.to_i]
    unless evidence
      return entry.merge(
        "verdict" => "missing",
        "review_evidence" => { "id" => evidence_id, "state" => "missing" }
      )
    end

    presented = entry.merge("review_evidence" => evidence_payload(evidence))
    presented["verdict"] = evidence.state if evidence.state.in?(%w[pending failed stale])
    presented
  end

  def evidence_ids(entries)
    Array(entries).filter_map do |entry|
      next unless entry.is_a?(Hash)

      (entry["review_evidence_id"] || entry[:review_evidence_id]).presence
    end
  end

  def evidence_payload(evidence)
    {
      "id" => evidence.id,
      "state" => evidence.state,
      "provider" => evidence.provider,
      "model" => evidence.model,
      "reviewed_base_sha" => evidence.reviewed_base_sha,
      "reviewed_head_sha" => evidence.reviewed_head_sha,
      "canonical_diff_sha256" => evidence.canonical_diff_sha256,
      "terminal_failure_code" => evidence.terminal_failure_code,
      "terminal_failure_details" => evidence.terminal_failure_details
    }.compact
  end
end
