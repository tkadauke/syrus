require "rails_helper"

RSpec.describe CognitiveReview::DebtRollup do
  it "summarizes PR-level cognitive review debt by note state" do
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

    %w[open open acknowledged discussed dismissed].each_with_index do |state, index|
      CognitiveReview::Note.create!(
        job: job,
        workflow: workflow,
        run: run,
        diff_review_version: version,
        path: "app/models/job_#{index}.rb",
        side: "new",
        start_line: 4,
        end_line: 4,
        title: "Review note #{index}",
        explanation: "Operator attention requested.",
        state: state,
        source_metadata: {}
      )
    end

    expect(described_class.for(job: job, diff_review_version: version).as_json).to eq(
      total_flagged_ranges: 5,
      open_unhandled_count: 2,
      acknowledged_count: 1,
      discussed_count: 1,
      dismissed_count: 1,
      handled_count: 2,
      zero_note_state: false
    )
  end

  it "treats an empty submission as a zero-note no-debt state" do
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

    expect(described_class.for(job: job, diff_review_version: version).as_json).to include(
      total_flagged_ranges: 0,
      open_unhandled_count: 0,
      handled_count: 0,
      dismissed_count: 0,
      zero_note_state: true
    )
  end
end
