module CognitiveReview
  module Artifact
    KEY = "cognitive_review_notes"

    module_function

    def append!(run:, notes:)
      workflow = run.workflow
      entries = Array(workflow.artifact(KEY))
      entries << {
        "run_id" => run.id,
        "job_id" => run.job_id,
        "submitted_at" => Time.current.iso8601,
        "notes" => notes
      }
      workflow.set_artifact!(KEY, entries)
    end

    def latest_notes_for(job)
      job.workflows.order(created_at: :desc, id: :desc).lazy
        .map { |workflow| Array(workflow.artifact(KEY)).last }
        .find(&:present?)
        .to_h.fetch("notes", [])
    end
  end
end
