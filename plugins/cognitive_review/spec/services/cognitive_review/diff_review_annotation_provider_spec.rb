require "rails_helper"

RSpec.describe CognitiveReview::DiffReviewAnnotationProvider do
  it "projects submitted workflow notes for the requested diff version into review annotations" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
    note = CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 4,
      end_line: 6,
      title: "Check lifecycle",
      explanation: "This range changes lifecycle behavior.",
      source_metadata: {}
    )

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
        id: "cognitive_review_note:#{note.id}",
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
    run = workflow.runs.first
    old_version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
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
    CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: old_version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 4,
      end_line: 4,
      title: "Old note",
      explanation: "This belongs to an older diff.",
      source_metadata: {}
    )

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

  it "counts acknowledged and discussed notes as handled rather than unresolved debt" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
    CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 4,
      end_line: 4,
      title: "Handled note",
      explanation: "Already handled.",
      state: "acknowledged",
      source_metadata: {}
    )

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: version,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    expect(payload[:ranges]).to eq({})
    expect(payload[:counts]).to contain_exactly(hash_including(id: "cognitive_review.open", value: 0))
  end
end
