require "rails_helper"

RSpec.describe CognitiveReview::DiffReviewAnnotationProvider do
  it "projects submitted workflow notes for the requested diff version into review annotations" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: workflow.runs.first,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
    workflow.set_artifact!(CognitiveReview::Artifact::KEY, [
      {
        "run_id" => workflow.runs.first.id,
        "job_id" => job.id,
        "workflow_id" => workflow.id,
        "diff_review_version_id" => version.id,
        "base_sha" => "base",
        "head_sha" => "head",
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
      version: version,
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

  it "does not fall back to stale notes from an unrelated diff version" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    old_version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: workflow.runs.first,
      base_sha: "old-base",
      head_sha: "old-head",
      files: []
    )
    new_version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: nil,
      base_sha: "new-base",
      head_sha: "new-head",
      files: []
    )
    workflow.set_artifact!(CognitiveReview::Artifact::KEY, [
      {
        "run_id" => workflow.runs.first.id,
        "job_id" => job.id,
        "workflow_id" => workflow.id,
        "diff_review_version_id" => old_version.id,
        "base_sha" => "old-base",
        "head_sha" => "old-head",
        "submitted_at" => Time.current.iso8601,
        "notes" => [
          {
            "id" => "stale-note",
            "path" => "app/models/job.rb",
            "side" => "new",
            "start_line" => 4,
            "end_line" => 4,
            "title" => "Old note",
            "body" => "This belongs to an older diff."
          }
        ]
      }
    ])

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: new_version,
      base_sha: "new-base",
      head_sha: "new-head",
      files: []
    )

    expect(payload).to eq({})
  end
end
