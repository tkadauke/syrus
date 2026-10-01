require "rails_helper"

RSpec.describe CognitiveReview::Note, type: :model do
  let(:job) { Factories.job_with_run(step_attrs: { kind: "post_implementation_review" }) }
  let(:run) { job.initial_run }
  let(:workflow) { job.latest_workflow }
  let(:version) do
    DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
  end

  def build_note(**attrs)
    described_class.new({
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 12,
      end_line: 14,
      title: "State transition edge",
      explanation: "Check whether the new transition is reachable.",
      reason_codes: %w[state],
      confidence: 0.82,
      priority: "high",
      source_metadata: {}
    }.merge(attrs))
  end

  it "allows dismissed notes while keeping handled scoped to acknowledged and discussed notes" do
    dismissed = build_note(state: "dismissed")
    dismissed.save!

    expect(dismissed).to be_valid
    expect(dismissed).not_to be_handled
    expect(described_class.handled).not_to include(dismissed)
    expect(described_class.dismissed).to include(dismissed)
  end

  it "derives side-aware new ranges from the submitted range" do
    note = build_note

    expect(note).to be_valid
    expect(note).to have_attributes(
      new_start_line: 12,
      new_end_line: 14,
      old_start_line: nil,
      old_end_line: nil
    )
  end

  it "derives side-aware old ranges when reviewing the old side" do
    note = build_note(side: "old", start_line: 3, end_line: 5)

    expect(note).to be_valid
    expect(note).to have_attributes(
      old_start_line: 3,
      old_end_line: 5,
      new_start_line: nil,
      new_end_line: nil
    )
  end

  it "rejects invalid ranges" do
    note = build_note(start_line: 0, end_line: 0)

    expect(note).not_to be_valid
    expect(note.errors[:start_line]).to be_present
  end

  it "rejects graph records from another job" do
    other_job = Factories.job_with_run
    note = build_note(workflow: other_job.latest_workflow)

    expect(note).not_to be_valid
    expect(note.errors[:workflow]).to include("must belong to the same job")
  end
end
