require "rails_helper"

RSpec.describe CognitiveReview::DiffReviewAnnotationProvider do
  it "projects latest submitted workflow notes into review annotations" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    workflow.set_artifact!(CognitiveReview::Artifact::KEY, [
      {
        "run_id" => workflow.runs.first.id,
        "job_id" => job.id,
        "submitted_at" => Time.current.iso8601,
        "notes" => [
          {
            "id" => "note-1",
            "path" => "app/models/job.rb",
            "side" => "new",
            "start_line" => 4,
            "end_line" => 6,
            "title" => "Check lifecycle",
            "body" => "This range changes lifecycle behavior.",
            "tone" => "warning"
          }
        ]
      }
    ])

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: nil,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    expect(payload.dig(:ranges, "app/models/job.rb")).to contain_exactly(
      hash_including(
        id: "note-1",
        side: "new",
        start_line: 4,
        end_line: 6,
        title: "Check lifecycle"
      )
    )
    expect(payload[:counts]).to contain_exactly(hash_including(id: "cognitive_review.open", value: 1))
  end
end
