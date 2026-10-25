module Steps
  class ReviewPanelCollect < Base
    def call
      details = step.details.to_h
      review_kind = details.fetch("panel_review_kind")
      artifact_key = Step::Kind.fetch(review_kind).review_gate.fetch(:artifact_key)
      entries = Array(workflow.artifact(artifact_key))
      votes = entries.select do |entry|
        entry["panel_id"] == details["panel_id"] && entry["iteration"].to_i == step.iteration && !entry["aggregate"]
      end
      result = ProviderRouting::PanelConsensus.call(
        member_verdicts: votes,
        consensus: details.fetch("consensus"),
        min_members: details.fetch("min_members")
      )
      entries << {
        "iteration" => step.iteration,
        "panel_id" => details["panel_id"],
        "aggregate" => true,
        "verdict" => result.verdict,
        "votes" => votes.map { |vote| vote.slice("provider", "model", "verdict") },
        "consensus" => details["consensus"],
        "dropped_members" => details["dropped_members"],
        "non_blocking_findings" => result.verdict == "approved" ? votes.select { |vote| vote["verdict"] == "needs_work" }.map { |vote| vote.slice("provider", "model", "critique") } : []
      }
      workflow.set_artifact!(artifact_key, entries)
      if result.verdict == "skipped" && details["required"]
        fail_with!(:required_review_unavailable, "required #{review_kind} panel did not meet its minimum member count")
      end
    end
  end
end
