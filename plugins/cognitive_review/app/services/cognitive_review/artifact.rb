module CognitiveReview
  module Artifact
    KEY = "cognitive_review_notes"

    module_function

    def append!(run:, notes:)
      workflow = run.workflow
      version = DiffReviewVersion.best_match_for(job_id: run.job_id, run_id: run.id, workflow_id: workflow.id)
      entries = Array(workflow.artifact(KEY))
      entries << {
        "run_id" => run.id,
        "job_id" => run.job_id,
        "workflow_id" => workflow.id,
        "diff_review_version_id" => version&.id,
        "base_sha" => version&.base_sha,
        "head_sha" => version&.head_sha,
        "submitted_at" => Time.current.iso8601,
        "notes" => notes
      }.compact
      workflow.set_artifact!(KEY, entries)
    end

    def notes_for(job:, version:, base_sha:, head_sha:)
      matching_entry_for(job: job, version: version, base_sha: base_sha, head_sha: head_sha)
        .to_h.fetch("notes", [])
    end

    def matching_entry_for(job:, version:, base_sha:, head_sha:)
      job.workflows.order(created_at: :desc, id: :desc).lazy
        .flat_map { |workflow| Array(workflow.artifact(KEY)).reverse }
        .find { |entry| entry_matches?(entry, version: version, base_sha: base_sha, head_sha: head_sha) }
    end

    def entry_matches?(entry, version:, base_sha:, head_sha:)
      payload = entry.to_h
      return true if version && payload["diff_review_version_id"].to_i == version.id

      expected_base_sha = version&.base_sha.presence || base_sha.to_s.presence
      expected_head_sha = version&.head_sha.presence || head_sha.to_s.presence
      return false if expected_base_sha.blank? || expected_head_sha.blank?

      payload["base_sha"].to_s == expected_base_sha && payload["head_sha"].to_s == expected_head_sha
    end
  end
end
